# Test harness

Boots the real host configurations in VMs on a virtual network and asserts
things about the running system — services healthy, ports bound where they
should be, secrets decrypted, a real tailnet formed, traffic reaching a service
through Caddy — rather than only that the Nix and YAML parse.

Everything runs offline and reproducibly. Container images are pinned to
content-addressed digests and loaded from the Nix store, so a suite that passes
today passes identically next month.

## Running

```bash
./tests/run.sh              # lints only — seconds
./tests/run.sh vps          # VPS: caddy + headscale + a real tailnet
./tests/run.sh services     # services VM: sops -> arcane -> stacks
./tests/run.sh tailnet      # both hosts on one tailnet, end to end
./tests/run.sh disko        # disk-config.nix formats, mounts, and boots
./tests/run.sh media        # heavy: full media stack — kill-switch, x265 guard, EICAR
./tests/run.sh immich       # heavy: photo stack — config render, v3 API, reboot durability
./tests/run.sh all

./tests/run.sh debug vps    # live VM + Python REPL
```

Run `./tests/run.sh` (lints) constantly — it is a few seconds and catches the
cross-file contracts. Run a VM suite when you have changed something it covers.

### Debugging a failure

`run.sh debug <suite>` builds the interactive driver and drops you into a REPL
with every machine available:

```python
start_all()
headscale_vps.shell_interact()               # root shell in the guest
print(headscale_vps.succeed("systemctl --failed"))
print(headscale_vps.succeed("journalctl -u caddy --no-pager | tail -50"))
```

This is the only practical way to work out why an assertion failed six minutes
into a boot sequence.

## Why this is not a flake

Flakes only see git-tracked files. Most of what you want to test is untracked
while you are working on it, so every edit would need a `git add` before it
could be tested — and if the host directories were path inputs, every edit
would also need a re-lock. Plain Nix has neither problem: relative paths just
work and iteration is instant.

`nixpkgs` is pinned from `headscale-vps/flake.lock` (see `lib/sources.nix`), so
the suites evaluate against exactly the nixpkgs the hosts are built with. The
`nixpkgs-parity` lint fails if `nixos/flake.lock` drifts from it, because a
suite testing against a different nixpkgs than the host is built with is a
green light that means nothing.

## Layout

| Path | What it is |
|------|-----------|
| `default.nix` | Entry point. `checks`, `driver`, and the evaluated production configs under `config`. |
| `lib/sources.nix` | Pins nixpkgs + sops-nix from the host's own lock file. |
| `lib/images.nix` | **Generated.** Content-addressed pins for every image. |
| `lib/profiles.nix` | The test-only overrides, each with the reason it exists. |
| `lib/lints.nix` | Pure contract checks, run against production values. |
| `suites/*.nix` | The VM suites. |
| `fixtures/*.sops.env` | Fake secrets, encrypted to the throwaway key below. |
| `keys/test-age-key.txt` | **Throwaway age key, committed on purpose.** |
| `update-images.sh` | Regenerates `lib/images.nix`. |

### The committed key is not a leak

Three throwaway keypairs are committed: `keys/test-age-key.txt` (decrypts only
`tests/fixtures/*.sops.{env,yaml}`, all values like
`test_pg_password_not_secret`), `keys/test-ssh-key` (SSH login assertions),
and `keys/test-storagebox-key` (the in-VM SFTP endpoint). It is committed so the harness runs
without the production key. `.sops.yaml` gives fixtures their own creation rule,
listed **first**, so `sops -e` on a fixture cannot accidentally encrypt to the
production recipient.

Using real sops rather than stubbing secrets is deliberate: a secret that fails
to decrypt, or lands with the wrong owner or mode, is a real deploy failure on
both hosts and one that config review does not catch.

## What is actually asserted

Beyond "it parses":

- **Secrets** decrypt at activation with the right owner and mode
  (`headscale 400` for the OIDC secret), and `$`-containing values survive
  intact — the quoting hazard `CLAUDE.md` warns about.
- **Bindings**, checked from another host: headscale on `127.0.0.1:8080` and
  not `0.0.0.0`; metrics on loopback only; every stack port loopback-only;
  Caddy on the services VM bound to the tailnet IP alone.
- **Firewall negatives**: the off-tailnet `outsider` node can reach 22/80/443
  on the VPS and nothing else — 9000 and 9443 in particular, which were open
  before `modules/caddy.nix` landed and exposed Authentik's admin interface
  over plain HTTP.
- **ACME for real**: Caddy runs its actual ACME client through a real HTTP-01
  challenge against Pebble. Only the CA differs from production.
- **A real tailnet**: both hosts join via `tailscale-autoconnect` — including
  `--login-server`, whose absence makes a node register against Tailscale's
  SaaS and silently never appear — then peers ping over 100.64/10 and a client
  reaches Arcane through Caddy by hostname.
- **Boot ordering**: `docker-network-homelab` really does activate before
  `bootstrap-arcane`, compared by timestamp rather than by reading the unit.
- **The failure signal**: a unit is deliberately failed and the harness asserts
  the alert arrives in Ntfy. If that path is broken every other failure on the
  host is silent.
- **Reboot**: both suites reboot and re-assert, which catches missing
  `wantedBy`/ordering that a `nixos-rebuild switch` never exercises.
- **Independence**: headscale keeps serving with `docker` stopped — the stated
  reason it is a native service.
- **Brute-force protection, both layers**: the vps suite proves the authentik
  fail2ban jail is loaded and runs the deployed failregex against the
  empirically captured `login_failed` line plus three negative controls
  (successful login, `invalid_login`, an asgi access line — none may match);
  the authentik suite walks the reputation policy → DenyStage binding → flow.
  The `fail2ban-journal-contract` lint pins the compose journald tag to both
  `journalmatch` consumers.
- **The gluetun kill-switch, offline by construction**: the media fixture
  points wireguard at TEST-NET-1, so the suite runs with the tunnel
  permanently down and proves qBittorrent's netns has zero egress beyond the
  docker subnet (positive controls from a sibling container) while the
  loopback UI and the arr→qbit path stay alive.
- **x265 enforcement mechanically**: a TRaSH-style `x265 (HD)` custom format
  injected at −10000 via the API is zeroed by `media-init`'s guard, and both
  arrs are swept for x264-favouring scores.
- **The ClamAV chain**: EICAR dropped into the downloads tree is quarantined
  within one poll interval; a clean file is untouched.

## What it cannot cover

Honest list; do not read a green suite as covering these.

| Not covered | Why |
|---|---|
| Let's Encrypt, Cloudflare DNS-01 | No internet in the sandbox. Pebble covers the ACME client; the production endpoint and the public A records are not exercised. |
| Real DNS (`*.svc.idanreed.com`) | `/etc/hosts` stands in. |
| Hetzner / Proxmox provisioning | `nixos-anywhere`, `qmrestore`, cloud-init. |
| The literal `/dev/sda` in `disk-config.nix` | The `disko` suite (disko's own `makeDiskoTest`) formats, mounts, and legacy-boots the config — but rewrites the device to the runner's virtio disk, and overrides disko's own `boot.loader.grub.devices` derivation with its test scaffolding's. |
| The production secret *values* decrypting | Needs the production key. The `sops-declared` lint verifies the real files' key sets (sops-yaml keys are plaintext). |
| Caddy's cloudflare-dns plugin at work | Since 2026-08-30 the suites load the REAL published fork image (a broken xcaddy build fails caddy startup and the services suite with it), but they force `tls internal`, so the plugin's DNS-01 flow against Cloudflare is never exercised. |
| Hetzner Storage Box itself | The backrest suite runs a real in-VM SFTP endpoint instead — key, sftp, restic, snapshots all real; only the endpoint's address is substituted. |
| Real OIDC browser login | The authentik suite verifies the secret contract, blueprint objects, and discovery; the interactive flow is not driven. |
| Dictionarry profile content / gluetun turning healthy / HW transcode | The media suite runs offline: Profilarr's DB link needs egress (the WARN fallback is asserted instead), gluetun's healthcheck dials through the tunnel (started detached; the `depends_on … restart: true` contract is real-host-only), and no GPU exists in the VM (the guarded `/dev/dri` stanza is asserted to exist, nothing more). |
| A real fail2ban ban / a real reputation lockout | The vps suite never provokes an actual ban (bantime would race every later ssh subtest) and no suite saturates reputation to -10; the filter/policy *logic* is what's asserted. The journal-routing contract (tag → journalmatch) is lint-recovered, not runtime-exercised. |
| Immich ML inference / live OIDC login | The immich suite runs offline: model download and every inference *result* (smart search hits, faces, duplicates) need egress — the suite pins the degraded-but-healthy state instead (ML answers `/ping`, smart search errors, server stays up). The OIDC browser + `app.immich:///oauth-callback` flow is doubly uncoverable (needs a browser AND v3's secure-OAuth default vs the suite's plain-HTTP loopback); the rendered config contract and the authentik-side provider are asserted instead. |

Where an override costs coverage, `lib/profiles.nix` names the loss and, where
possible, a lint recovers it against the real value.

## Findings from building this

### 1. Headscale could not start at all

```
FTL Error initializing error="loading configuration: Fatal config error:
    dns.nameservers.global must be set when dns.override_local_dns is true"
```

Removing `dns.nameservers.global` was correct — it pointed at a CoreDNS that
was never deployed. But headscale 0.27 defaults `override_local_dns` to
**true**, and true with no global nameservers is fatal. Headscale crash-looped
(restart counter 20) and the VPS came up with no control plane.

Fixed in `modules/headscale.nix` by setting `override_local_dns = false`, which
is what the surrounding comment already intended.

### 2. sops-nix does not extract per-key values from dotenv files — FIXED

`sops-install-secrets` treats `dotenv` exactly like `binary`:

```go
switch s.Format {
case Binary, Dotenv, Ini:
    s.value = sourceFile.binary   // whole file; s.Key is never applied
```

`validateSopsFile` skips key validation for the same three formats, so nothing
warns. The option docs only say "ignored if format is binary", which is what
makes this easy to walk into.

Both hosts set `defaultSopsFormat = "dotenv"`, so **every `/run/secrets/<name>`
holds the entire decrypted document**:

| Consumer | Effect |
|---|---|
| `nixos/configuration.nix` | `tailscale up --authkey "$(cat …)"` gets a multi-line dotenv; registration fails |
| `modules/headscale.nix` | `oidc.client_secret_path` likewise — and silently, since `only_start_if_oidc_is_available = false` |
| `modules/authentik.nix` | `sops.templates` substitutes the value, so `PG_PASS` becomes the whole document |

`decrypt-sops-envs.service` is **not** affected — it shells out to the sops CLI,
where the whole file genuinely is the artifact.

**Fixed by migrating OS-level secrets to per-host `secrets.sops.yaml` (yaml
format)**, while stack `.env` files stay dotenv (consumed whole — correct).
The real files exist with placeholder values encrypted to the production
recipient (encryption needs only the public key); edit real values in with
`sops <host>/secrets.sops.yaml`. The migration also fixed the VPS flake's
eval failure (`.sops.env` never existed). The `sops-dotenv-extraction` lint
stays as the regression guard, and `sops-declared` now verifies the real
files' key sets — sops-yaml keeps top-level keys plaintext.

Remaining user step: copy the real `TAILSCALE_AUTH_KEY` value from the old
`nixos/.sops.env` into `nixos/secrets.sops.yaml`, then delete the old file
(its other keys had no consumer anywhere).

### 3. Three image references could not be pulled at all

So the stacks could never have started:

| Reference | Problem |
|---|---|
| `ghcr.io/getarcaneapp/arcane:1.17.4` | Upstream tags with a leading `v`. Fixed to `v1.17.4`. |
| `ghcr.io/civilblur/mazanoke:1.1.5` | Same. Fixed to `v1.1.5`. Note `bentopdf` does *not* use a `v`, which is why `update-images.sh` resolves every reference against the registry rather than trusting it. |
| `ghcr.io/idanreed/caddy-cloudflare:2.11.2` | Never published — `.github/workflows/build-caddy.yml` has not been run. Substituted with upstream `caddy:2.11.2` in the suites. **Run that workflow before deploying the caddy stack.** |

### 4. config-init needed the network to boot

`stacks/backrest/compose.yaml` ran `apk add gettext` inside config-init at
container start — a registry outage at boot took the whole backup stack down,
and the offline suite could never pass. Replaced by
`stacks/backrest/config-init.sh` (busybox-only awk substitution) which also
hard-fails on unset/empty variables where envsubst silently wrote `""`.

### 5. Backrest crash-loops when the storage box is unreachable at startup

backrest 1.9.1's `autoInitialize` is fatal at orchestrator start: box
unreachable ⇒ exit ⇒ `restart: unless-stopped` loop ⇒ **UI down for the whole
outage**. An outage *after* startup leaves the UI alive. Accepted behaviour
(decision 2026-08-30) — the backrest suite's outage matrix pins down both
sides of the asymmetry so an image bump changing either fails a test.

### 6. The documented admin-password command could never log in

Backrest base64-decodes `passwordBcrypt` before comparing
(`internal/auth/auth.go`), but `.sops.env.example` said to store the raw
bcrypt — every login would fail `invalid password` with no way in. Docs now
say `htpasswd ... | base64 -w0`, and the suite logs in with the fixture
credentials and triggers a real backup, so the encoding contract stays tested.

### 7. The OIDC blueprint was invisible to Authentik

Blueprint discovery globs `**/*.yaml`; the file was `headscale-oidc.yml`.
Mounted, readable, and silently never discovered — no provider, no
application, no users, no error anywhere. On the production VPS, OIDC
provisioning would simply never have happened. Renamed to `.yaml`; the
authentik suite polls the applied objects through the API, so a regression
re-fails loudly.

### 8. Every backup notification — including the dead-man ping — was undeliverable

backrest v1.9.1 *defines* `actionWebhook` in its proto and accepts it in
config, but ships **no handler** for it: every hook fired
`no handler for hook type *v1.Hook_ActionWebhook` at runtime. All four hooks
in `config.template.json` used it, so no ntfy notification and no dead-man
ping would ever have been delivered — the exact silent-monitoring hole the
hooks exist to prevent. Rewritten to `actionShoutrrr` (ntfy) and
`actionHealthchecks` (dead-man, gaining success/fail URL semantics). Caught
because the suite triggers a *real* backup, which fires the hooks.

### 9. One comment-only key killed the whole OIDC blueprint

The group entry carried `attrs:` with only comments beneath — YAML parses
that as `null`, and authentik's importer calls `.items()` on it. The
resulting `AttributeError` aborts the ENTIRE blueprint apply (provider,
application, users — everything), retried forever, with the error visible
only in worker logs. Combined with finding 7, OIDC provisioning had two
independent ways to silently not exist.

### 10. GitOps delivery was dead on arrival — ownership

Arcane runs as PUID 1000; `/srv/stacks` was root-owned. Its sync could never
`mkdir` a project directory and its deploys could not read the root-0600
`.env` files — the GitOps model was inert on the production host. Fixed:
`/srv/stacks` is 1000:1000 (tmpfiles) and `decrypt-sops-envs` chowns each
`.env` to 1000. The gitops suite now runs the full loop (push → sync with
`syncDirectory` → decrypt → deploy → update) against the real Arcane API.
Two adjacent doc corrections: v1.17.4's `syncDirectory` defaults OFF per
sync, and sync never deploys — that is a separate API/UI action.
Corollary caught by the sweep: with sync-delivered files owned 1000, mounting
`ssh_config` at `/root/.ssh/config` breaks — root's ssh refuses non-root-owned
config. It now mounts at `/etc/ssh/ssh_config`, which has no ownership check.

### 11. `env_file: .env` made every stack unsyncable

Arcane's gitops sync validates the compose file in a staging directory
*before* copying it in; the host-side decrypted `.env` cannot exist there, so
a plain `env_file: .env` fails validation and the whole stack's sync aborts —
for **every** stack in the fleet, deterministically. Fixed with the long form
(`path: .env, required: false`): staging validates, deploys still load the
decrypted file. Residual window (documented in each compose): a deploy racing
the first decrypt starts with unset vars; services' own healthchecks are the
loud guard. Caught when the gitops suite's test project gained an `env_file`.

### 12. Forward auth through the public vhost could never work

Authentik's embedded outpost routes forward-auth checks by `X-Forwarded-Host`
— which any Caddy REPLACES unless the caller's IP is in `trusted_proxies`.
Dialled at `https://auth.idanreed.com`, the VPS Caddy sees the (dynamic,
unpinnable) home IP, rewrites the header, and the outpost 404s every check.
Fixed: the `(protected)` snippet dials the VPS **over the tailnet** by
MagicDNS name (with `tls_server_name`/`Host` pinned to the auth vhost) and
`modules/caddy.nix` trusts `100.64.0.0/10`. The forward-auth suite asserts
both directions — tailnet probes answer, an off-tailnet spoofed
`X-Forwarded-Host` stays stripped.

### 13. The embedded outpost built localhost URLs

Without `config.authentik_host` on the outpost, authorize/logout URLs are
built from `localhost` and every browser hop dead-ends. The forward-auth
blueprint sets it; the suite asserts the first unauthenticated hop 302s to
the fully-qualified authorize URL.

**Rollout order for the forward-auth change set** (operator note): rebuild
the VPS first (blueprint + trusted_proxies), then redeploy the caddy stack —
flipping `import protected` before the outpost exists locks you out of the
pilot service.

### 14. Seerr crash-loops on a root-owned bind mount

`ghcr.io/seerr-team/seerr` runs as `USER node` (uid 1000) and EACCES-loops on
`mkdir /app/config/logs` against the root-owned directory docker auto-creates
for an absent bind source. Fixed with a `seerr-init` chown oneshot the app
container depends on. The same class of bug is why every stack's bind sources
deserve explicit ownership, not docker defaults.

### 15. qBittorrent 401s on the published port, silently

qBittorrent's host-header validation rejects any `Host` whose **port**
differs from its internal listen port — both the `127.0.0.1:10057` publish
and a Caddy vhost get a bare 401 with nothing in the logs. Root-caused by
repro (`Host: 127.0.0.1:18080` → 401, `Host: 127.0.0.1` → 200). `qbit-init`
seeds `WebUI\HostHeaderValidation=false`; the DNS-rebinding defence it
disables is moot behind loopback + Caddy.

### 16. Compose inherits healthchecks you did not ask for

Running a second container from the `clamav/clamav` image (the scan watcher)
inherits the image's baked-in healthcheck, which probes a clamd that
container does not run — permanently `unhealthy`, failing any `up --wait`.
Override the healthcheck with the dependency the container actually has.

The `env-file-coverage` lint also warns that `backrest`, `caddy` and `ntfy`
declare `env_file: .env` but have only `.sops.env.example` — `docker compose up`
aborts on a missing env file, so those stacks will not start until the real
`.sops.env` is created.

## Status

Every suite is green as of 2026-08-30: lints (**16** — the newest:
`forward-auth-coverage`, every `import protected` Caddyfile host must have a
blueprint provider assigned to the embedded outpost; `ssh-pubkey-parity`,
the three ssh-pubkeys.nix copies stay byte-identical; and
`fail2ban-journal-contract`, the compose journald tag agrees with both
journalmatch consumers), vps, services, tailnet,
authentik, paperless, backrest, **rotation** (the restartUnits contract),
**gitops** (the full Arcane push→sync→decrypt→deploy loop, against a REAL
in-VM Forgejo remote over http — the git-daemon transport substitution is
retired), **forgejo** (healthz, headless admin seed, API repo, credentialed
push + clone-back), **forward-auth** (redirect/spoof/no-lockout + API
contract), **media** (24 subtests: gluetun kill-switch offline by
construction, both-sided x265 guard proven against injected TRaSH artifacts,
EICAR→quarantine chain), **immich** (20 subtests: make-style config render
incl. secret rotation, headless admin seed, v3 multipart upload → asset →
thumbnail without ML, the literal backup-prepare `pg_dumpall` loop body with
content checks, reboot durability on a real persistent disk), **proxmox-boot**
(image boots, cloud-init key, sops decrypt), disko,
stackChecks, and the proxmox image build gate (`run.sh all` covers the lot).
**Sixteen** production findings came out of building it — see the ledger above. Remaining coverage work is tracked in the workspace-level LONGRUN.md:
per-stack suites as stacks land (Phase 4). Forward auth and the
boot-the-proxmox-image suite are in (see `run.sh forwardauth` /
`run.sh proxmox-boot`). Not coverable: authentik's authenticated browser
flow (JS flow executor + enforced TOTP; the API-level delivery contract is
asserted instead), so the first real login stays a manual post-deploy check.
