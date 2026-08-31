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
./tests/run.sh books        # heavy: book stack — headless seeding, OPDS, :ro mounts, hook
./tests/run.sh automation   # heavy: HA storage config, MQTT round trip, frigate safe-mode gate
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
| Caddy's cloudflare-dns plugin | The suites force `tls internal`; only routing is covered. |
| Hetzner Storage Box itself | The backrest suite runs a real in-VM SFTP endpoint instead — key, sftp, restic, snapshots all real; only the endpoint's address is substituted. |
| Real OIDC browser login | The authentik suite verifies the secret contract, blueprint objects, and discovery; the interactive flow is not driven. |
| Dictionarry profile content / gluetun turning healthy / HW transcode | The media suite runs offline: Profilarr's DB link needs egress (the WARN fallback is asserted instead), gluetun's healthcheck dials through the tunnel (started detached; the `depends_on … restart: true` contract is real-host-only), and no GPU exists in the VM (the guarded `/dev/dri` stanza is asserted to exist, nothing more). |
| A real fail2ban ban / a real reputation lockout | The vps suite never provokes an actual ban (bantime would race every later ssh subtest) and no suite saturates reputation to -10; the filter/policy *logic* is what's asserted. The journal-routing contract (tag → journalmatch) is lint-recovered, not runtime-exercised. |
| Immich ML inference / live OIDC login | The immich suite runs offline: model download and every inference *result* (smart search hits, faces, duplicates) need egress — the suite pins the degraded-but-healthy state instead (ML answers `/ping`, smart search errors, server stays up). The OIDC browser + `app.immich:///oauth-callback` flow is doubly uncoverable (needs a browser AND v3's secure-OAuth default vs the suite's plain-HTTP loopback); the rendered config contract and the authentik-side provider are asserted instead. |
| The Coral TPU, real cameras, and the IoT VLAN | The automation suite has no TPU and no RTSP sources. A missing Coral is a **crash loop**, not a degradation (the watchdog SIGTERMs PID 1), so the suite overrides the detector block with `type: cpu` — the tested config differs from the deployed one in exactly the block that fails hardest. What is covered instead: the guarded `/dev/bus/usb` stanza is asserted to exist and Frigate to run without the device, and Frigate is asserted **not to be in safe mode** (an invalid config does not crash it — it starts with `cameras: {}` and MQTT off, reporting healthy). Object detection, recording, snapshots and the IoT-VLAN broker path are untouched. Home Assistant's discovery integrations (mDNS/SSDP/DHCP) are inert on a bridge network by design; the suite cannot tell that from broken, so it asserts neither. |
| Anna's Archive, and both apps' OIDC logins | The books suite runs offline: every AA search/download and the Cloudflare-bypass browser need egress, as does every metadata/cover provider — so shelfmark is only asserted to come up and stay healthy with zero egress, and the libraries index from the EPUB's own OPF and the audio file's tags alone. Both OIDC integrations ship *off* (their client secrets need the production age key), so what is asserted is the deliberate off-state — Kavita reporting `enabled: false`, audiobookshelf advertising `["local"]` — not a login, and not the ON-state render path. KOReader on the reMarkable is tablet-side entirely; the server half (OPDS feed, sync endpoint, auth key) is covered. |

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

### 17. Kavita signs every JWT with a published placeholder key, silently

Kavita rewrites its own `config/appsettings.json` (JWT key generation at
startup, and every settings change), and **all six writers are wrapped in a
bare `catch { /* Swallow exception */ }`**. The shipped template contains a
literal placeholder `TokenKey` that is in the public repository.

So a read-only config mount — which is exactly what the immich stack does with
its rendered `immich.json`, and the obvious thing to copy — does not crash and
does not log a failure: the server carries on signing every session token with
a key anyone can read. The only tell is a `Generating JWT TokenKey…` line that
looks identical on a healthy first run.

Fixed before it shipped: `stacks/books/` mounts the config directory
**writable** and `kavita-config-init` pre-seeds a real `KAVITA_TOKEN_KEY` from
sops, and the books suite re-reads the file *after* Kavita has started to
prove the seeded key is still the one in play. The same swallow hits settings
writes, so on a read-only mount Kavita's admin UI would also appear to accept
OIDC settings and then quietly revert them on the next boot.

Adjacent, from the same service: Kavita computes "is OIDC enabled" **two
different ways** — `Authority && ClientId && Secret` on the disk side (which
decides whether OIDC is registered) and **`Authority` alone** on the DB side
(which the login path consults). An authority with no secret is therefore a
half-configured state, not an off one, and it is the state in which
`disablePasswordAuthentication` would disable password login fleet-wide
against an OIDC that does not exist. `kavita-config-init` blanks the authority
whenever the secret is empty so both computations agree.

### 18. Audiobookshelf's headless paths carry three loaded guns

All three found by reading the source before writing the init container, and
all three are silent or destructive rather than loud:

1. **`POST /init` with a malformed body kills the server.** The route calls
   `initializeServer` without `await` and without a `.catch()`, so a missing
   `newRoot` becomes an unhandled rejection and the process handler does
   `Logger.fatal` + `process.exit(1)`. A connection reset on `/init` means
   "the server just exited", not "retry". (The scan endpoint has the same
   shape: `res.sendStatus(200)` then an unguarded `await` — a scan that throws
   takes the server down *after* the client saw its 200.)
2. **`password: ""` silently creates a passwordless root user** — 200 response,
   a `Logger.warn`, and a local auth strategy that then approves any login
   submitting an empty password. A `.env` value that failed to interpolate
   produces an open admin account that looks like a successful seed.
3. **`authOpenIDSubfolderForRedirectURLs` defaults to the literal string
   `undefined`**, never normalised to `""`, and the redirect URI is built by
   template interpolation — so a headless `PATCH` that omits the key makes
   audiobookshelf offer the IdP
   `https://host/undefined/auth/openid/callback` and every login dies on a
   redirect_uri mismatch. The settings UI hides this by defaulting the field
   itself, so it only bites automation.

Plus a quieter one: if any required OIDC field is missing,
`ServerSettings.construct()` strips `openid` from the active auth methods on
the **next load**, with no log line at all — so OIDC must be asserted after a
restart, not after the PATCH.

### 19. A hook that is handed its payload on stdin cannot use the fleet's `python3 - <<EOF` idiom

Every init script here is a `/bin/sh` wrapper around `exec python3 - <<'PY'`,
which feeds the interpreter its script on **stdin**. Shelfmark's
`CUSTOM_SCRIPT` hook is invoked with its task document on stdin — so written
that way the hook silently reads the heredoc instead of the payload. Caught in
self-review before the suite ran; the wrapper now slurps stdin *before*
exec'ing python, with a `timeout` around the read (an inherited-but-never-closed
stdin would otherwise block until shelfmark's 300s hook timeout kills it, and
a killed hook is a non-zero exit).

Two more properties of that hook worth keeping in mind, both because a
non-zero exit **marks a completed download as Error in the UI**: it must be
mode **755** (shelfmark execs it directly, unlike every other script here,
which compose runs as `/bin/sh <script>`) — note the fleet's
`cp -r --no-preserve=mode` seed idiom sets files to 0644 and had to be worked
around in the suite — and its `except` clause must be `Exception`, not a
tuple of network errors: the JSON helper returns raw text on a non-JSON
response, so a 502 page from a restarting service surfaces as an
`AttributeError` two lines later.

### 20. A configured output for a source that cannot produce input

Shelfmark exposes a full audiobook pipeline (`DESTINATION_AUDIOBOOK`,
`FILE_ORGANIZATION_AUDIOBOOK`, `TEMPLATE_AUDIOBOOK_ORGANIZE`), and the obvious
reading — one container feeding both a Kavita ebook tree and an Audiobookshelf
audiobook tree — is wrong: Anna's Archive direct download declares
`supported_content_types = ["ebook"]`, and the only audiobook source is
AudiobookBay, a **torrent** source available solely under
`SEARCH_MODE=universal`. Under `SEARCH_MODE=direct` those three variables
configure a pipeline nothing can ever feed, and the audiobook bind mount grants
write access for downloads that cannot happen.

Caught by adversarially verifying the research annex against upstream source
rather than against its own variable list. The stack ships without them, and
the gap ("how do audiobooks actually arrive?") is an operator question rather
than a silently empty library.

### 21. A JWT key one byte too short, reported as "user already exists"

Found by the books suite's first real run, and it is two bugs stacked so that
each hides the other.

Kavita signs its JWTs with HMAC-SHA512 over the **raw UTF-8 bytes of the
`TokenKey` string** and rejects anything under 512 bits. The fixture's key was
62 characters — 496 bits — and the failure did not appear at startup: the
container went healthy, `/api/health` answered, and the first *register* call
threw `IDX10720: … the key size must be greater than: '512' bits, key has
'496' bits` deep inside the JWT handler.

The second half is what made it expensive. Kavita's register handler catches
its own exceptions, deletes the half-created user and returns **400** — the
same status it returns when an admin already exists. `books-init` treated 400
as "already seeded", logged a cheerful no-change line, and then failed on the
login that followed with a message blaming the operator's `.env`. The real
cause was only visible in `docker logs kavita`.

Two fixes, both worth keeping: `.sops.env.example` now specifies
`openssl rand -hex 64` and says why (note `-hex 32` yields exactly 64
characters — *on* the boundary, not safely past it), and `books-init` keeps
the register response body and reports both hypotheses when the follow-up
login fails, naming IDX10720 explicitly.

Same run also pinned down two filenames that were guesses:
`/mnt/fast/kavita/config/kavita.db` and
`/mnt/fast/shelfmark/config/users.db` both exist and are now asserted by the
suite rather than left to `backup-prepare.sh`'s silent skip.

### 22. `enableMetadata: false` means "index nothing", not "stay offline"

The books stack is built to need no egress, so the Kavita library was created
with every metadata-shaped flag off. One of them does not mean what it reads
like. `enableMetadata` does **not** control external providers — it controls
whether the parser reads the metadata **inside the file**. `BookParser` calls
`BookService.ParseInfo` only when it is set; with it false the parser falls
back to the filename, which for a Book library produces an empty `Series`, and
`ParseFile` logs *"Unable to parse any meaningful information out of file"*.

The visible symptom is a scan that succeeds and finds nothing: *"Found 1 files
for /books/Test Author"* immediately followed by *"Found 0 Series that need
processing"* and *"Finished library scan of 0 series … There were no changes"*.
A deployment would have looked entirely healthy with an empty library.

The genuinely external switches are `allowMetadataMatching` and
`allowScrobbling`; those stay false. Reading the EPUB's own OPF is local, and
is the reason this design chose Kavita over a Calibre-based stack in the first
place.

### 23. The `mqtt:` block every Home Assistant guide shows is silently invalid

Home Assistant's MQTT integration is config-flow only, and its YAML schema
accepts **platform names alone** (`sensor:`, `light:`, …). A `mqtt:` block
carrying `broker`/`port`/`username`/`password` — which is what essentially
every guide, forum post and older design doc shows, and what this stack's
first draft had — comes back as *extra keys not allowed*. There is no
YAML-to-config-entry import path left.

The failure is the bad kind: HA logs `Invalid config for 'mqtt'`, **starts
anyway**, serves a healthy `/manifest.json`, and simply never connects to the
broker. Frigate's events never reach Home Assistant, and every surface a
deployment check would look at is green.

The broker connection is a config **entry**, so `automation-init` creates it
through the config-flow REST API (`POST /api/config/config_entries/flow` with
`{"handler": "mqtt"}`, then the broker step) using the token it already holds
from onboarding. It is idempotent for free — the integration declares
`single_config_entry`, so a second run aborts with `single_instance_allowed`.

Caught in review, before it shipped. The suite now asserts the entry exists
and is `loaded`, and separately that Frigate published `online` to
`frigate/available` — a topic that only exists if Frigate authenticated to the
broker, unlike a log grep for "mqtt" which is unfalsifiable.

### 24. A proxy role map that grants nobody anything

Frigate's `proxy.header_map` can read a role out of a forwarded header, and
the obvious configuration — `role: x-authentik-groups` with a sensible
`default_role: viewer` — reads like it grants admin to the right people. It
does not. Without an explicit `role_map`, Frigate takes its *direct* path,
where the valid role set is exactly `{admin, viewer}` and a user is admin only
if one of their groups is **literally named `admin`**.

With Frigate's own login disabled in favour of forward auth, that means a
deployment with no `role_map` is permanently read-only **with no admin route
at all** — and nothing errors, because collapsing to `default_role` is the
designed behaviour. The fix is `role_map: {admin: [<group>]}` plus an
Authentik group that actually exists.

Adjacent, same class: `proxy.separator` defaults to `,` while Authentik joins
group values with `|`. A mismatch also silently collapses everyone to
`default_role`.

The `env-file-coverage` lint also warns that `backrest`, `caddy` and `ntfy`
declare `env_file: .env` but have only `.sops.env.example` — `docker compose up`
aborts on a missing env file, so those stacks will not start until the real
`.sops.env` is created.

### 25. A namespaced variable in a shared `.env` is invisible to the app

Every stack gets one `.env`, shared by every container in it, so prefixing a
key with the service name reads like good hygiene: `BOOKSTACK_APP_KEY` next to
`HBOX_AUTH_API_KEY_PEPPER` and `NEXTAUTH_SECRET`. It is not hygiene, it is a
rename. `env_file` injects the variable **verbatim**; BookStack reads `APP_KEY`
and there is no mapping layer, so the prefixed name simply leaves it unset.

The consequence is specific to that image and much worse than a crash: an
unset `APP_KEY` makes its init script `sleep infinity` rather than exit. The
container reports `running` forever, no restart policy fires, and there is no
exit code to alert on. Only the `/status` healthcheck notices.

The rule is that a `.env` key is named by **the application that reads it**,
never by the service it belongs to — `HBOX_*` and `NEXTAUTH_SECRET` are
correctly prefixed only because that is what Homebox and next-auth actually
read. Prefix only where the app itself does.

### 26. "No such tag in the registry" was a claim the tooling never checked

`update-images.sh` ran `nix-prefetch-docker` once per image with `2>/dev/null`
and, on any non-zero exit, recorded `UNRESOLVED — no such tag in the registry`.
`nix-prefetch-docker` exits non-zero for a manifest 404, a registry 5xx, a rate
limit, a TLS reset and a mid-pull disconnect alike, and the large images hit
the transient ones often enough that a full run kept reporting a
"deploy-blocking" bad tag for `immich-machine-learning:v3.1.0` — which a
manifest HEAD against ghcr answered `200`, and which resolved on the very next
attempt.

That is worse than an unhelpful error: it is a confident, wrong diagnosis that
sends you looking for a tag-shape bug in a compose file that is correct. The
fix is three attempts with backoff and **keeping stderr** — the message now
prints the actual last error and says outright that this is only a bad tag if
the error mentions an unknown manifest.

There is a second lesson under the first, worth stating because it cost more
than the bug did: the same failure was initially blamed on overlapping runs of
the script, which was *also* a real defect (no locking, and a
"wait for the tmpfile" guard that fires before the tmpfile exists). Both causes
were real, and fixing the one you found first is not evidence that it was the
only one.

### 27. A healthcheck that lies can disable a whole service, not just mislead

Finding #16 is about inherited healthchecks that probe the process instead of
the application. Dawarich shows the sharper edge of it: `depends_on` with
`condition: service_healthy` makes a wrong healthcheck **load-bearing for
something else's existence**.

`APPLICATION_PROTOCOL=https` installs `ActionDispatch::SSL` with `force_ssl`,
and there is no `ssl_options` exclusion anywhere in that codebase. The
container healthcheck sends no `X-Forwarded-Proto`, so Rails 301s it to
`https://127.0.0.1:3000`; wget follows; Puma speaks plain HTTP; the handshake
fails. The container is then permanently `unhealthy` — and upstream declares
`sidekiq.depends_on.app.condition: service_healthy`, so **Sidekiq never starts
at all**. Imports and statistics hang forever, with a web UI that looks
perfect and an error surface that is empty.

The fix is one flag on the probe (`--header='X-Forwarded-Proto: https'`), but
the general rule is the point: when a healthcheck gates a `depends_on`, a
false negative is not a monitoring problem, it is an outage of a *different*
container. Suites should assert the dependent service is alive by its own
evidence — here, that Sidekiq registered a heartbeat in Redis — not by the
health status of the thing it depends on.

The mirror image is in the same stack and just as instructive:
`config.host_authorization` explicitly **excludes** the health endpoint, so a
wrong `APPLICATION_HOSTS` yields a healthy container, a happy Arcane, a happy
Uptime Kuma — and a 403 "Blocked hosts" on every browser request. Any smoke
test of a reverse-proxy route must fetch `/` with the real `Host:` header;
the health endpoint is exactly the one path that cannot detect that class of
failure.

### 28. Running a one-off command in an image whose entrypoint does the setup

Provisioning a Rails app headlessly wants `rails runner` in a throwaway
container built on the same image — no docker socket, database reached over
the compose network. It fails in a way that looks like a broken image.

Dawarich's Dockerfile sets `ENV BUNDLE_PATH=/usr/local/bundle/gems`, which
contradicts the `bundle config --local path vendor/bundle` baked into
`.bundle/config`. Bundler gives the environment variable precedence, so
`bundle exec` resolves against an empty gem path. Both real entrypoint scripts
open with `unset BUNDLE_PATH BUNDLE_BIN` for exactly this reason — a one-off
container skips those scripts (it must; they end in `exec`) and therefore has
to repeat the fix itself.

The same class caught the worker command: `sidekiq-entrypoint.sh` ends in a
hardcoded `exec bundle exec sidekiq` and **ignores its arguments entirely**,
while upstream's compose still passes `command: ['sidekiq']`. Carrying that
forward is harmless but implies the command is configurable, which it is not.

Before running anything in an image by a path other than its entrypoint, read
the entrypoint. The first few lines are usually undoing something the
Dockerfile did.

### 29. Soft delete plus a unique index means "deleted" still owns the identity

Dawarich seeds `demo@dawarich.app` / `safepassword` as an **active admin**,
guarded only by `User.none?`, and re-runs `db:seed` on every boot. The obvious
neutralisation — create the real admin, destroy the demo one — silently does
not work. `SoftDeletable` overrides `User#destroy` to call `mark_as_deleted!`
and deliberately never calls `super`, so the row stays, no `dependent:
:destroy` cascade fires, and `index_users_on_email` is a plain UNIQUE index
with no `deleted_at IS NULL` predicate — so the "deleted" account keeps
holding that email forever.

Renaming the seeded account in place sidesteps all of it and leaves exactly
one user. But the durable lesson is about the assertion, not the fix: the
suite's most valuable check is the **negative** one — that
`demo@dawarich.app` / `safepassword` no longer authenticates. A provisioning
step that silently did nothing would leave a published-password admin on a
database of everywhere the operator has physically been, and every other
assertion in the suite would still pass. (`safepassword`, not `password`,
which is what stale guides say — a negative assertion against the wrong
credential passes against a completely unprovisioned instance.)

### 30. Compose interpolates `env_file` values, so a `$` in a secret is destroyed

CLAUDE.md already said any value containing `$` must be single-quoted in the
plaintext `.sops.env`, and attributed it to "the decrypt-and-source path". That
attribution is wrong — `decrypt-sops-envs` runs `sops -d` into a file and
sources nothing. **Docker Compose is the interpolator**, and it interpolates
values read from `env_file`, not just those written inline.

Verified in a throwaway compose project, one value written three ways:

```
SQ='$argon2id$v=19$m=65540,t=3,p=4$c2FsdA$aGFzaA'   ->  $argon2id$v=19$m=65540,t=3,p=4$c2FsdA$aGFzaA
BARE=$argon2id$v=19$m=65540,t=3,p=4$c2FsdA$aGFzaA   ->  =19=65540,t=3,p=4
DQ="$argon2id$v=19$m=65540"                          ->  =19=65540
```

Single quotes pass through verbatim. Bare and double-quoted forms lose
`$argon2id`, `$v` and `$m` to empty-variable expansion, and the container
receives a *different, shorter string* — no error, no warning.

What makes this a finding rather than a footnote is the failure downstream.
Vaultwarden's admin handler dispatches on a literal `$argon2` prefix test, so a
mangled token falls through to a **plaintext compare** of whatever you type
against that mangled string. `/admin` then rejects everything, and the only
clue is a startup line reading `[NOTICE] You are using a plain text ADMIN_TOKEN
which is insecure` — accurate, misleading, and easy to scroll past on a first
boot. The vaultwarden suite therefore checks the value as the *container* sees
it and then performs a real login round trip; only the round trip distinguishes
"configured" from "mangled".

Also worth knowing: upstream's advice to `$$`-escape is for an inline
`environment:` block. In an `env_file` it would arrive as a literal doubled
dollar.

### 31. An identity decision that no configuration can implement

Worth recording because the failure was not in any one component and no amount
of image-shopping fixes it. The intended design was Samba authenticating
against authentik's LDAP outpost — a single identity source for the file
shares. It cannot be built:

- **SMB2/3 offers only NTLMSSP or Kerberos.** There is no plaintext credential
  for Samba to forward as an LDAP simple bind; `client plaintext auth` has been
  deprecated since Samba 4.13.
- **`ldapsam` requires `sambaSamAccount`/`sambaNTPassword`** in the directory.
  authentik's outpost emits `top, person, user, organizationalPerson,
  inetOrgPerson, goauthentik.io/ldap/user, posixAccount` — nothing
  samba-shaped — stores PBKDF2 (from which MD4 cannot be derived), and is
  bind-and-search only, so Samba cannot write the hash itself either. authentik
  #25313 is open and tagged `pr_wanted`.
- **No `winbindd`** in any candidate image, so `security = ADS` is out.
- **nixpkgs builds Samba `--without-ldap --without-ads`**, so the
  native-service route is worse rather than better.

The generalisation: "service X authenticates against IdP Y" is a claim about a
*protocol path*, not about configuration, and the place it usually breaks is
the hash format — an IdP that stores a modern password hash cannot serve a
protocol that needs a specific legacy one. Check the protocol before promising
the integration. The fallback here is local users with usernames mirroring the
IdP, which keeps offboarding to one edit without pretending to be SSO.

### 32. The inventory claimed an authentication that was not there

`ServerNotes/designs/_overview.md`'s Auth column is the only written record of
what is supposed to guard each service, and it was wrong in both directions at
once. **Arcane** — which mounts the Docker socket, making its web UI
root-equivalent on this host — was marked `FwdAuth` while its Caddy route
imported nothing, so the only thing in front of it was its own login.
Mazanoke had the same gap with far lower stakes. In the other direction,
rmfakecloud was marked `FwdAuth` when forward auth would break the tablet
outright, and Syncthing was marked `LDAP` for a service with no LDAP worth the
coupling.

Every one of those was found by a human reading the row, which is not a
control. `auth-column-parity` now fails the build when a row claims `FwdAuth`
and the Caddy handle for its port does not `import protected`.

One implementation note that is the actual lesson: the first version keyed on
the row's NAME, and silently degraded `Firefly III` (served at `firefly.svc`)
and `OnlyOffice DocSpace` (`onlyoffice.svc`) to warnings — that is, to no
coverage at all, for exactly the rows most worth covering. A lint whose
matching heuristic can miss is a lint that reports success on the cases it
cannot see. It keys on the **port** now, which appears verbatim in both files.

### 33. A Laravel `APP_KEY` that is one byte too long, visible only at /status

BookStack's `APP_KEY` is a Laravel AES-256-CBC key, so `base64:` plus **exactly
32 raw bytes**. A fixture key decoded to 37. Nothing rejected it.

The container started. Every migration ran — all ~180 of them, printed to the
log. LSIO's `/custom-cont-init.d` hook ran and reported the admin replaced.
`[ls.io-init] done.` The site served HTML. The only symptom was
`GET /status` returning 500, and the reason was in `laravel.log`:

```
RuntimeException: Unsupported cipher or incorrect key length.
Supported ciphers are: aes-128-cbc, aes-256-cbc, aes-128-gcm, aes-256-gcm.
  at Illuminate/Encryption/Encrypter.php:61
  ... Illuminate/Foundation/Http/Kernel.php(215): terminateMiddleware()
```

Note where it is thrown: **during middleware termination**, after the response
has already gone out. So the page renders, the request looks fine, and every
session cookie and encrypted column is silently broken.

Two things this confirms:

- **The healthcheck choice was load-bearing.** `/status` is one of the few
  probes in this fleet that is honest by construction — it exercises database,
  cache and session and returns 500 if any fails. A `/` probe, or the "is the
  process up" reflex, would have shipped this. That is finding #16 read the
  other way round: when you pick the probe deliberately, it catches things the
  application itself never reports.
- **Length rules on keys need a machine check, every time.** This is the third
  in the campaign, after Kavita's 512-bit `TokenKey` (#21) and Firefly's
  exactly-32-character `APP_KEY`. All three fail late, quietly, and in a way
  that points somewhere other than the key. The tracking and firefly suites now
  each assert the length directly, so the failure names its own cause instead
  of arriving as a 500 an hour later.

### 34. `wget --spider` is a HEAD request, and GET-only routes answer 405

Homebox sat `unhealthy` for 152 seconds in a suite run while its own log showed
migrations complete, `Server is running on :7745`, and — for every single probe
— `request finished method=HEAD path=/api/v1/status status=405`.

The probe was `wget -q --spider http://127.0.0.1:7745/api/v1/status`.
`--spider` means "don't download the body", which wget implements as a **HEAD**.
Homebox registers that route for GET only, so it returns 405, which wget treats
as failure. The application was perfectly healthy the whole time; the probe was
asking a question the router refuses to answer.

This is a different shape from finding #16. There the healthcheck lies by
passing — it probes the process and reports healthy for a broken app. Here it
lies by failing, which is less dangerous but wastes a whole suite run and, in
production, would have `depends_on: service_healthy` hold back everything
downstream of a service that is fine.

`wget -q -O /dev/null <url>` is a GET and costs nothing extra on a health
endpoint. Use it unless you have specifically verified the route accepts HEAD.
The `books` and `media` stacks keep `--spider` because their suites are green
against those endpoints, which is the proof this rule asks for — the point is
not that HEAD is wrong, it is that HEAD is an assumption most people do not
know they are making.

### 35. MariaDB 11 dropped `mysqldump`, and the backup would have shipped broken

`backup-prepare.sh`'s MySQL branch ran

    docker exec bookstack_db sh -c 'exec mysqldump -u root -p"$MYSQL_ROOT_PASSWORD" --all-databases'

and `mariadb:11.8.9` answered `sh: 1: exec: mysqldump: not found`. MariaDB 11.x
removed the `mysql*` compatibility symlinks entirely — the image ships
`mariadb-dump`, `mariadb-admin`, `mariadb-check` and so on, and nothing named
`mysql*` at all.

This one is loud rather than silent: exit 127 sets `rc=1`, which trips
`OnFailure` and reaches ntfy. But loud only helps after deployment. BookStack
would have gone live with no working database dump, and the first evidence
would have been a nightly alert about a service that had been running fine for
a week.

Two things worth carrying:

- **The env var keeps the `MYSQL_` spelling.** The image's entrypoint still
  accepts `MYSQL_ROOT_PASSWORD` as an alias for `MARIADB_ROOT_PASSWORD`, and
  `stacks/tracking/compose.yaml` sets it that way deliberately so this line can
  read it out of the container's own environment. Only the *binary* was
  renamed, which is precisely why the mistake is easy to make.
- **The suite runs the literal command**, not an approximation of it. That is
  the whole reason this was caught before deploy rather than after: an
  assertion that "a dump file exists" would have been satisfied by a dump
  produced any other way, and an assertion that "backup-prepare.sh mentions
  bookstack" would have been satisfied by the broken line.

The `backup-coverage` lint cannot catch this class — it checks paths and
container names, and no static check knows which binaries an image ships. The
suite is the control here.

### 36. A lint made vacuous by the one mount that covers everything

`backup-coverage` was written to catch the Karakeep class: a `sqlite_backup`
path pointing at a file no container creates, which the helper silently treats
as success. Its check was "the path must be inside a `/mnt` bind mount some
compose file declares".

`stacks/backrest` declares `- /mnt/fast:/mnt/fast:ro`, because snapshotting
everything is its job. So **every** path under `/mnt/fast` is inside a declared
mount, and the lint passed everything — including the exact bug it was written
for. It reported success on 18 paths and had verified nothing.

Excluding whole-tier mounts (`/mnt`, `/mnt/fast`, `/mnt/slow`) from the
evidence set makes the check mean what it says: only a **service-specific**
mount is evidence that some container actually writes there. That immediately
found a real one — a `sqlite_backup uptimekuma /mnt/fast/uptimekuma/kuma.db`
line for a stack that has never been built, a permanently-silent no-op sitting
in the script looking exactly like a working backup.

The general shape is worth keeping in mind when writing any cross-file check:
**if one entry in the corpus matches everything, the check is that entry.** Ask
what the most permissive row is before trusting a green result — and be
suspicious of a new lint that passes on the first run, which this one did.

### 37. Homebox answers 500 to a duplicate registration, so the second deploy failed

`tracking-init` provisions Homebox through `POST /api/v1/users/register`, and
handled an already-registered email by accepting 400/409/422 and confirming the
credentials still work. The first run was green. The second run — which is what
every Arcane redeploy does — exited 1:

    tracking-init: FATAL: homebox register HTTP 500:
    {"error":"ent: constraint failed: constraint failed:
     UNIQUE constraint failed: users.email (2067)"}

The ent unique-constraint violation is not translated into a client error at
all; it surfaces as a 500 with the database's message in the body. So the
idempotency contract every other init in this fleet is held to — *a second run
logs zero CHANGE lines and exits 0* — was broken from the start, and only a
suite that reruns the container found it.

The fix accepts 500 **only** when the body names that constraint. That
narrowness is the point: "the server broke" and "the user is already there" are
genuinely different, and here the body is the only thing that distinguishes
them. Widening it to "500 means fine" would turn a real outage into a silent
pass.

Worth generalising: **an init container that has only ever been run once has
not been tested.** Every stack suite in this repo now removes the init
container and brings it up again, precisely because first-run success says
nothing about redeploy behaviour — and redeploy is the common case.

### 38. rmfakecloud strips the hyphen from an email, on create but not on login

`sanitizeEmail` runs when an account is created and **not** when one is looked
up, so any character it removes produces an account nobody can log into. The
symptom is a bare 401, indistinguishable from a wrong password. Its own log is
the only place the truth appears:

```
Creating an admin user
[ui] stat /data/users/rm-admin@test.invalid/.userprofile:
     no such file or directory cannot load user, login failed
401 POST /ui/api/login
```

The whitelist is `[^a-zA-Z0-9.@-_]+`. In a character class `@-_` is an ASCII
**range**, 0x40–0x5F — `@ A-Z [ \ ] ^ _`. So the surviving set is letters,
digits, `.`, `@`, `_` and four punctuation oddities, and **the hyphen is
stripped**. Upstream discussion of this bug focuses on `+`, which is the
memorable case; the hyphen is the common one, and it is what this fleet's own
test fixture hit.

Two things worth carrying:

- **A character class containing an unescaped `-` between two characters is a
  range, not three literals.** Reading `@-_` as "at-sign, hyphen, underscore"
  is the natural mistake and produces exactly the wrong mental model. When a
  whitelist matters, enumerate what it *admits* rather than what you think it
  lists.
- The guard in `notes-sync-init.sh` now checks the email against the real
  admitted set rather than against `+`, and refuses up front. Validating input
  against a rule you derived by *reading* the regex — instead of by running
  it — is how the first version of that guard came to check for the wrong
  character.

### 39. `up --wait` fails when a one-shot exits, even with exit code 0

Every stack here that provisions itself has an init container with
`restart: "no"`, and `docker compose up -d --wait` reports:

    container notes_sync_init exited (0)

and returns 1. The exit code is right there in the message and is ignored —
`--wait` waits for containers to become *running or healthy*, and a container
that has finished is neither.

It is worse than a plain error because it is intermittent: whether the
one-shot has exited by the time `--wait` gives up depends on how long the rest
of the stack took to become healthy, so the same suite passes on a fast run and
fails on a slow one. Two suites here passed with this bug in them before one
finally caught it.

The fix is to enumerate the long-lived services in the `up` command and wait
for the one-shots separately, by exit code — which is the thing that actually
matters about them:

    up -d --wait --wait-timeout 900 rmfakecloud syncthing
    ...
    wait_until_succeeds("docker inspect -f '{{.State.Status}}/{{.State.ExitCode}}' "
                        "notes_sync_init | grep -qx exited/0")

The `tracking` suite had done it this way from the start, for exactly this
reason; the newer suites had drifted to the shorter form because it reads
better. It reads better and is wrong.

### 40. A container that downloads its own database driver at every start

ExcaliDash's entrypoint runs `npx prisma generate` unconditionally on boot, and
its `prisma/schema.prisma` hardcodes:

```
binaryTargets = ["native", "linux-musl-arm64-openssl-3.0.x",
                 "linux-musl-openssl-3.0.x"]
```

The image bakes only the engines for its own architecture, so `generate` always
reaches for the other one:

```
Error: request to https://binaries.prisma.sh/.../
  linux-musl-arm64-openssl-3.0.x/libquery_engine.so.node.gz.sha256
  failed, reason: getaddrinfo EAI_AGAIN binaries.prisma.sh
```

On amd64 it needs the arm64 engine; on arm64 it would need the other. There is
no skip flag in the entrypoint. So this is not "degraded without egress" — it
is a **crash loop** on a tailnet-only host, and the service is deferred.

This is finding #4 (a container that fetches from the network to become
functional) in its sharpest form yet, and worth recording because of *when* it
was caught. The compose file parsed, the pins resolved, all nineteen lints
passed, and the image's healthcheck and env vars were all correct. Nothing
short of booting it offline could have found this — which is the argument for
suites that run with no network rather than suites that mock one.

The same run also caught that the secrets had been named
`EXCALIDASH_JWT_SECRET` and `EXCALIDASH_CSRF_SECRET` while the application
reads the **bare** `JWT_SECRET` and `CSRF_SECRET`. That is finding #25
recurring in a file whose own comments warn about it: the container had been
quietly auto-generating both into its volume, which is exactly the state the
`.sops.env.example` said to avoid.

### 41. Documenting a templating syntax inside the file that is templated

Glance resolves environment references over the **raw file text, before YAML
parsing**, so a dollar-brace reference anywhere in `glance.yml` is substituted —
comments included. A missing variable is a hard startup error, repeated forever
because the container restarts:

    Config has errors: parsing variable: environment variable ENV_VAR not found

The reference that broke it was inside a comment *warning about this exact
behaviour*. The comment named the syntax literally in order to explain it, and
naming it was enough to trigger it.

The behaviour itself is the good kind of loud — a typo'd variable name fails at
boot rather than rendering an empty string into a widget. The lesson is about
the comment: in any file that is preprocessed, **describe a syntax in words
rather than writing it**, because a preprocessor has no concept of "this one is
just documentation". The same trap exists in Compose files (`$$`), systemd
units (`%`), and anything rendered through envsubst.

### 42. `up --wait` errors on a healthcheck-less service — but only if you name it

Compose refuses outright:

    container windmill_worker has no healthcheck configured

Windmill's worker has `healthcheck: disable: true` on purpose — it has no HTTP
listener, so any container-level probe would be the process check finding #16
exists to warn about, and its liveness is asserted from the server's worker
list instead. Naming it explicitly in `up -d --wait` turns that deliberate
absence into a hard error.

The asymmetry is the trap: `up -d --wait` over the **whole project** tolerates
a service with no healthcheck and simply waits for it to be running. Naming the
same service explicitly does not. So the fix for finding #39 — enumerate the
long-lived services rather than waiting on everything — introduced this one,
because the enumeration included a service whose healthcheck was deliberately
absent.

Both rules together: enumerate the long-lived services **that have
healthchecks**, and assert everything else by its own evidence.

## Status

Every suite is green as of 2026-08-30: lints (**19** — the three newest:
`auth-column-parity`, a `_overview.md` row claiming FwdAuth must have a Caddy
handle that imports `protected` (it caught Arcane, the socket-mounting UI,
guarded by nothing but its own login — finding 32); `backup-coverage`, every
`sqlite_backup` path must live inside a **service-specific** bind mount some
compose file declares and every service in the `pg_dumpall` loop must have the
matching `container_name` and `POSTGRES_USER`, because that helper returns 0
for a MISSING source. The "service-specific" qualifier is load-bearing and was
missing from the first version: `stacks/backrest` mounts `/mnt/fast:ro`
wholesale, so accepting any declared mount made the check **vacuous** — the
Karakeep bug it was written for would have passed. Excluding whole-tier mounts
immediately found a real one, a `uptimekuma` line for a stack that has never
been built; and `host-network-declared`, every non-default `network_mode`
must be listed with its reason, because such a service does not FAIL
`loopback-binding` — it passes with an empty port set. Also
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
content checks, reboot durability on a real persistent disk), **books** (21 subtests: the sops -> render -> merge chain including that
Kavita did not silently replace the seeded JWT key, headless seeding of two
apps in one oneshot and its idempotence, a real EPUB and a real FLAC indexed
with zero egress, OPDS end to end plus the KOReader auth leg, the deliberate
OIDC-off contract, the `:ro` library mounts measured rather than reasoned, the
post-download hook in both directions including that it still exits 0 when its
target is down, and reboot durability on a real disk), **automation** (21 subtests: the pre-seeded `.storage/http` proving Home
Assistant loaded a STABLE config rather than a five-minute trial, a real
proxied request, Frigate asserted NOT to be in safe mode, the MQTT round trip
with auth on plus both consumers proven connected, the sha512-pbkdf2 password
hash that keeps the file readable by the pinned 2.0.x broker, Frigate's
unauthenticated port 5000 asserted unpublished, and reboot durability),
**tracking** (bookstack + its MariaDB, homebox, karakeep + meilisearch +
chrome: the seeded `admin@admin.com` proven dead, two tRPC/204-no-body
bootstraps, and Karakeep's version endpoint pinned so an accidental `latest`
— which self-reports `nightly` — cannot pass), **firefly** (the
`remote_user_guard` header spelling proven from the database side, the guard's
total lack of validation pinned deliberately, and the php-fpm-ping healthcheck
caught lying with the database stopped), **dawarich** (the force_ssl/Sidekiq
interlock, host authorization asserted with a wrong `Host` as the control, and
the seeded `demo@dawarich.app` proven dead across a reboot), **proxmox-boot**
(image boots, cloud-init key, sops decrypt), disko,
stackChecks, and the proxmox image build gate (`run.sh all` covers the lot).
**Forty-two** production findings came out of building it — see the ledger above. Remaining coverage work is tracked in the workspace-level LONGRUN.md:
per-stack suites as stacks land (Phase 4). Forward auth and the
boot-the-proxmox-image suite are in (see `run.sh forwardauth` /
`run.sh proxmox-boot`). Not coverable: authentik's authenticated browser
flow (JS flow executor + enforced TOTP; the API-level delivery contract is
asserted instead), so the first real login stays a manual post-deploy check.
