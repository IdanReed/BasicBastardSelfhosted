# Test harness

Boots the real host configurations as NixOS VM tests on a virtual network and
asserts runtime behaviour: services healthy, ports bound where they should be,
secrets rendered with the right owner and mode, a real tailnet formed, traffic
reaching a service through Caddy, a push deploying through Komodo. A green run
means more than "the Nix and YAML parse".

Everything runs **offline**. Container images are pinned to content-addressed
digests (`lib/images.nix`) and loaded from the Nix store, so a suite that
passes today passes identically next month, and anything a container would
download at runtime has to be provided another way.

## Running

```bash
./tests/run.sh              # structural lints — seconds, must stay green
./tests/run.sh deploy-check # lints + deploy-readiness (sops-declared) + operator to-do scan
./tests/run.sh <suite>      # one named VM suite (table below)
./tests/run.sh stack <name> # one stack alone — the fast loop for stack work
./tests/run.sh disko        # disk-config.nix formats, mounts and boots
./tests/run.sh proxmox      # build gate for the Proxmox VMA image
./tests/run.sh proxmox-boot # boots the image: cloud-init key -> sops decrypt
./tests/run.sh all          # everything
./tests/run.sh debug <suite>  # interactive driver: live VMs + a Python REPL
```

Run the lints constantly. Run `deploy-check` before a live deploy. Run a VM
suite when you have changed something it covers.

`run.sh`'s header lists every target with a one-line purpose, next to the
`case` it documents. Its named-suite arm and `default.nix`'s `suites` are
mirrored by hand; the `run-sh-suite-parity` lint fails if they drift.

CI (Forgejo Actions, self-hosted runner): `lints.yml` runs the lints on every
push, `suites.yml` runs `vps`, `services` and `tailnet` on pull requests, and
`heavy-nightly.yml` runs `./tests/run.sh all`.

### Debugging a failure

```python
# ./tests/run.sh debug vps
start_all()
headscale_vps.shell_interact()               # root shell in the guest
print(headscale_vps.succeed("systemctl --failed"))
print(headscale_vps.succeed("journalctl -u caddy --no-pager | tail -50"))
```

The REPL is the practical way to see why an assertion failed minutes into a
boot sequence.

## Why this is not a flake

Flakes see only git-tracked files, so every edit to an in-progress module
would need a `git add` before it could be tested. Plain Nix has no such
restriction: relative paths work and iteration is immediate.

`nixpkgs`, `sops-nix` and `disko` are pinned from the repo-root `flake.lock`
(`lib/sources.nix`) — the one lock both servers build from — so the suites
evaluate against exactly the nixpkgs the hosts run. The lints evaluate the real
host configs, so the real `secrets.sops.*` files must be present (their keys
are plaintext; no private key is needed).

## Layout

| Path | What it is |
|---|---|
| `default.nix` | Entry point: `checks`, `stackChecks`, `driver`, `all`, and the evaluated production configs under `config` |
| `run.sh` | The only thing you invoke. Its header is the target list |
| `lib/sources.nix` | Pins nixpkgs, sops-nix and disko from the root `flake.lock` |
| `lib/images.nix` | **Generated** by `update-images.sh`: a digest pin per image reference |
| `lib/profiles.nix` | The test-only overrides, each with the coverage it costs |
| `lib/lints.nix` | Structural contract checks against production values |
| `lib/mk-stack-suite.nix` | The generic per-stack suite, derived from a compose file |
| `suites/*.nix` | The hand-written VM suites |
| `fixtures/` | Fake secrets encrypted to the throwaway key: `stacks/<name>.sops.json`, `shared.sops.json`, the hosts' `*.sops.yaml`, `secrets-recovery.sops.yaml` |
| `keys/` | Throwaway keypairs, committed on purpose (below) |
| `update-images.sh` | Regenerates `lib/images.nix`; run it after any image tag change |

### The committed keys are not a leak

`keys/test-age-key.txt` decrypts only `tests/fixtures/`, whose values read like
`test_pg_password_not_secret`. `keys/test-ssh-key` drives SSH login
assertions; `keys/test-storagebox-key` is the in-VM SFTP endpoint's. They are
committed so the harness runs without the production key. `.sops.yaml` lists
the fixtures creation rule **first**, so `sops -e` on a fixture cannot encrypt
to the production recipient.

Fixtures go through real sops-nix rather than stubbed values: a secret that
fails to render, or lands with the wrong owner or mode, is a real deploy
failure that config review does not catch.

After changing an image tag, run `./tests/update-images.sh` (it resolves every
reference against its registry; `light` skips the multi-GB images and carries
their pins over). The `image-pins` lint fails while a pin is stale. The script
refuses to run twice at once (exit 99).

## The suites

One row per `run.sh` target, in the order its `case` accepts them. *Heavy*
suites pull multi-GB images and take several minutes: run them when you touch
what they cover and let the nightly sweep do the rest. The fleet-wide gaps in
**What it cannot cover** apply to every row.

| Target | What it proves | What it cannot |
|---|---|---|
| `vps` | The headscale VPS: Caddy through a real ACME (Pebble) HTTP-01 exchange, native headscale on loopback, `policy.hujson` loaded, the admin/API prefixes tailnet-only, the fail2ban jail's filter against a captured `login_failed` line, Alloy reading the journal with its token by path, a peer and the VPS joining the tailnet, headscale surviving `docker` stopped, firewall negatives, a reboot. | No services VM, so log shipping never delivers. Never provokes a real ban. |
| `services` | The services-VM boot chain: sops-nix renders every stack env (incl. `env.nix` built values and `$`-values single-quoted), `stack-env-publish` copies them root-only, `docker-network-homelab` before `bootstrap-komodo`, Komodo Core booting offline, the age key never reaching Periphery, the light stacks healthy, Caddy's routing table, `notify-failure@` reaching ntfy, `backup-prepare` dumping and failing loudly on a bad VPS key, a reboot with every timer armed. | Heavy stacks (own suites); loopback publishing probed from a tailnet peer (`tailnet`). |
| `tailnet` | Both hosts on one tailnet: `tailscale-autoconnect` with `--login-server`, Caddy bound to the tailnet IP only, a client reaching Komodo through Caddy by hostname, MagicDNS, `backup-prepare` pulling VPS state over the tailnet, loopback ports unreachable from a peer, an off-tailnet host reaching nothing. | The VPS → VictoriaLogs log hop. |
| `authentik` | *Heavy.* `authentik.service` converging with the project name pinned; the env template rendering per-key values; every custom blueprint applying; the headscale and immich providers and the three-way client-secret contract (fixture = headscale's secret file = the provider row); OIDC discovery through Caddy. | The browser login flow (JS flow executor + enforced TOTP). |
| `paperless` | *Heavy.* Five containers, the fixture admin minting an API token, a document travelling HTTP → redis → celery → postgres and back out of the API. | OCR of real scans; Caddy routing. |
| `backrest` | *Heavy.* `config-init` seeding `config.json` once (a `$`-laden restic password intact) and leaving it byte-identical on re-run; the storage-box-key gate both ways; ntfy reached by name over `homelab`; a real repository, login and snapshot over SFTP to an in-VM endpoint; the box-outage matrix. | Hetzner itself, its sub-account scoping and its snapshots. Never restores. |
| `rotation` | *Heavy.* A specialisation switch rotates `HEADSCALE_OIDC_CLIENT_SECRET`; `restartUnits` restarts headscale and authentik, and the new value reaches the worker. | Whether Authentik re-reads `!Env` into the provider row. |
| `gitops` | The deploy path offline: Komodo and Forgejo from their host units, `komodo-sync-bootstrap` creating the `fleet` sync and `apply` from the real `komodo/fleet.toml`, the tag-scoped sync leaving untagged resources alone, Forgejo's signed push webhook running `apply`, Periphery cloning from `forgejo:3000` and deploying a container that sees a value existing only encrypted; a compose change and a ciphertext change each redeploy; unsigned listener calls refused. | A Forgejo upgrade; Komodo deploying the real stacks. |
| `forwardauth` | *Heavy.* The bentopdf pilot across the host seam: `forward-auth.yaml` applied to the embedded outpost, `import protected` redirecting an unauthenticated tailnet request, a spoofed off-tailnet `X-Forwarded-Host` stripped, other vhosts not locked out. | An authenticated request passing through the gate (needs a browser). |
| `forgejo` | *Heavy.* `healthz`, the headless admin seed, an API token and repo, credentialed push and clone-back, push-to-create, anonymous access refused, web + ssh published on loopback only. | A real remote clone. |
| `media` | *Heavy.* The gluetun kill-switch offline by construction (WireGuard at TEST-NET-1: qBittorrent's netns has zero egress while its UI answers), the forwarded listen port, the inits (media, Jellyfin wizard, Seerr, Cleanuparr) idempotent, the two-sided x265 guard, the EICAR → quarantine chain including a pre-imported hardlink, the audiobook promotion, Seerr and Bazarr wiring. | Profilarr's DB link, gluetun turning healthy, hardware transcode (egress / GPU). |
| `immich` | *Heavy.* Config render including a rotated secret, the headless admin seed, a v3 multipart upload → asset → thumbnail without ML, smart search failing without killing the server, the `pg_dumpall` leg, reboot durability on a real disk. | ML results; the OIDC browser and `app.immich:///` callback. |
| `books` | *Heavy.* The sops → render → merge chain (Kavita's seeded JWT key still in play after start), OIDC on for both apps with Audiobookshelf's root carrying the SSO email, idempotent headless seeding, a real EPUB and FLAC indexed offline, OPDS and the KOReader auth leg, `:ro` mounts measured, the post-download hook, the audiobook drop folder. | Anna's Archive, metadata providers, a real OIDC login. |
| `automation` | *Heavy.* Home Assistant loading a pre-seeded stable `.storage/http`, proxied requests accepted, Frigate **not** in safe mode, the MQTT config entry and an authenticated round trip with both consumers connected, Frigate's port 5000 unpublished, reboot. | Coral TPU, cameras, the IoT VLAN (the detector is overridden to CPU). |
| `tracking` | *Heavy.* BookStack's seeded `admin@admin.com` proven dead, the Homebox and Karakeep bootstraps (204/tRPC), Karakeep's version equal to the pin, search actually registered, OIDC on with local login kept where needed, the backup paths, reboot. | Link scraping, OCR, AI. |
| `firefly` | *Heavy.* `APP_KEY` length, the `remote_user_guard` header spelling and its total lack of validation pinned, `/healthcheck` caught lying while `/health` does not, the cron token length, the host `firefly-cron` unit. | The forward-auth half in front of it. |
| `dawarich` | *Heavy.* The `force_ssl`/Sidekiq interlock, host authorization with a wrong-`Host` control, Sidekiq's heartbeat in Redis, the seeded `demo@dawarich.app` proven dead, PostGIS present, reboot. | A real GPS ingest client. |
| `vaultwarden` | The `ADMIN_TOKEN` PHC un-mangled from render to container and a real `/admin` round trip with a wrong-token control, signups closed, WAL mode and the `.backup` copy, `rsa_key.pem` present. | The forward auth on `/admin` (structural, by lint). |
| `notes-sync` | *Heavy.* The rmfakecloud create-once window closed, egress switches off in the running config, Syncthing's device identity surviving a reboot, and the inverted publish assertion: 22000 reachable, 10200/10201 not. | The reMarkable side. |
| `util` | No secrets at all, Glance offline, the static tools, and the `unhealthy-containers` alert firing once, recovering, and ignoring a container still in its start period. | Each tool's actual function. |
| `windmill` | *Heavy.* Both containers as uid 1000, the dependency cache seeded from the image (the bind mount that would delete the interpreters is a failure), the real superadmin in and `admin@windmill.dev` out, the worker registered, idempotent init. | Scripts running against real dependencies. |
| `restore` | The restore drill: `pg_dumpall` with `backup-prepare.sh`'s literal command → destroy → restore; `.backup` against a live WAL database; `sqlite_backup`'s silent no-op on a missing source pinned; `systemd-tmpfiles --create` restoring ownership; a full local restic loop (init → snapshot → destroy → restore → bytes and metadata compared → Vaultwarden starting on the restored key); wrong-password and flipped-byte negative controls. | The SFTP/Storage Box leg, an older repository format, the production password. |
| `tandoor` | *Heavy.* No `db.sqlite3` (the silent SQLite fallback), `SECRET_KEY` not the published fallback, the developer fixture account absent, the catch-all 200 pinned. | Recipe import from a real site. |
| `wger` | *Heavy.* `admin`/`adminadmin` proven dead, the real admin a superuser, a hashed static asset fetched through the nginx sidecar, gunicorn unpublished, `SECRET_KEY` surviving a reboot. | Exercise-database sync. |
| `mealie` | *Heavy.* `changeme@example.com` retired and proven 401, exactly one user, the database read back out of the SQLite file on the bind mount, signup closed. | Recipe scraping. |
| `actual` | *Heavy.* The headless bootstrap proven by a real login (and a wrong one refused), OIDC env inert on the server, state owned by uid 1001, the init failing closed on an empty or `changeme_` password. | Bank sync. |
| `wealthfolio` | *Heavy.* An Argon2id PHC surviving render → interpolation proven by a real login; negative-control containers for the boot-fatal traps (mangled hash, OIDC discovery, empty allowlist, missing env). | Market-data providers. |
| `gatus` | The `network_mode: host` bind proven from another machine (invisible to `loopback-binding` and the generic probe), and an empty config directory as a hard startup failure. | Probing a real fleet. |
| `docspace` | *Heavy.* The machine key in play is the sops one, Standalone mode holds, the wizard seeded headlessly and its token gone, Document Server's `/healthcheck` saying `true`, the `mysqldump` contract. | A document editing session. |
| `beszel` | *Heavy.* The key/token/signature triangle, the app user an admin, real disk numbers hub-side on two real block devices with neither tier dropped, a wrong key failing loudly, `config.yml`'s destructive `SyncSystems` pinned. | A multi-host fleet; long-run history. |
| `journald-logging` | The daemon-wide journald log driver: `docker logs` demultiplexed under it, `CONTAINER_TAG` = container name, rate limiting off (30,000 of 30,000 lines survive). | Not a stack suite — it guards what every `docker logs` assertion rests on. |
| `silverbullet` | *Heavy.* git-sync against a real in-VM Forgejo: seed, mirror round trip, PAT hygiene, the remote-wins reconcile with its saved branch and alert, the `CONTAINER_BOOT.md` canary, healthy through a dead remote, the 2.9.0 bump gate. | Client sync; a conflict needing a human. |
| `outline` | The OIDC redirect leg built from the compose/blueprint contract, migrations with the team unowned, uid-1001 upload writes, the `pg_dumpall` contract, stateless redis. | Any login — Outline has no local accounts. |
| `victorialogs` | *Heavy.* The ingest contract (a container's stdout queryable in the store with the label contract), retention flags in the running argv, data under `/mnt/slow/victorialogs`, vmui, Grafana healthy offline with the datasource plugin absent. | The VPS side of the hop; real dashboard queries. |
| `proton` | No creds and no egress: SMTP/IMAP/CardDAV listeners answer, an unauthorised IMAP login is a clean `NO`, the export loop fails calmly and leaves no success stamp. | Anything reaching Proton. |
| `excalidraw` | *Heavy.* A named scene persisted through Postgres (not process memory) across an api restart, the keyv table in its own database, registration closed with OIDC configured, the collab relay handshake. | A collaborative browser session. |

### Other targets

| Target | What it is |
|---|---|
| `lints` (default) | Every structural lint in `lib/lints.nix` against the real production values, plus one check only `run.sh` can make: no build artifact is git-tracked. |
| `deploy-check` | The same plus the deploy-readiness lints (`sops-declared`) and an informational scan: committed `changeme_` placeholders, `null` entries in `ssh-pubkeys.nix`, and exemptions still marked `TODO: decide —`. Red means the live host is not ready, not that the code is broken. |
| `stack <name>` | The generic per-stack suite (below). |
| `disko` | `headscale-vps/disk-config.nix` through disko's `makeDiskoTest`: formats, mounts, legacy-boots. |
| `proxmox` | Builds `.#proxmox-image` (a flake build, not a `tests` attribute). |
| `proxmox-boot` | Boots that image with a NoCloud seed; asserts the cloud-init age key and first-boot sops decryption through the guest agent. |
| `all` | Everything, including `diskoTest` and `proxmoxBoot`, which live outside `checks`. |
| `debug <suite>` | The interactive driver. |

### Generic stack suites

`./tests/run.sh stack <name>` boots the real services VM with only that stack
and asserts, generically: the fixture renders through sops-nix to a 0400 root
`/run/stack-env/<name>.env`, `docker compose up --wait` converges, every
published port answers on loopback and is refused from another node, and every
container is running (healthchecked ones healthy). Images, ports and `/mnt`
volume roots are derived from the compose file, and each `/mnt` bind source
gets the ownership from the generated `nixos/stack-dirs.nix`, so registering a
stack is one list entry in `default.nix`.

Registered: `ghostfolio`, `logging`, `ntfy`, `proton`, `owl`, `util`,
`outline`, `silverbullet`, `excalidraw`.

A stack needs a hand-written suite instead when the generic suite cannot make
its claim: a `restart: "no"` init one-shot fails the all-running check
(rule #39), a healthcheck reports healthy on a broken config, or the contract
is a protocol dialogue rather than a port answering. `caddy` has no generic
suite: it needs the DNS-01 → `tls internal` substitution and a `TAILNET_IP`,
and `services`/`tailnet` cover its routing.

## The lints

Pure checks over the repo and the evaluated host configs; no VM, seconds.
`sops-declared` runs only under `deploy-check`; every other lint is in the
default gate.

| Lint | Contract |
|---|---|
| `oidc-contract` | Each native-OIDC consumer agrees with its Authentik blueprint (slug, redirect URIs, `!Env` name present in both the worker env and the sops template); no provider name or application slug declared twice. |
| `sops-declared` | *deploy-check only.* Every `sops.secrets` name exists in the real host file, and its `.example` and every fixture carry the same key set. |
| `sops-dotenv-extraction` | OS-level sops files are yaml/json, never dotenv (rule #2). |
| `image-pins` | Every compose `image:` has a pin in `lib/images.nix`, and no pin outlives its reference. |
| `env-file-coverage` | A compose names only the env files the host renders: `/run/stack-env/<stack>.env` when the stack has secrets, plus one `<stack>.<part>.env` per `env.<part>.nix`. |
| `caddy-routes` | Every Caddy route points at a port something publishes. |
| `forward-auth-coverage` | Every `import protected` host has a forward-auth provider assigned to the embedded outpost (a missing one is a lockout). |
| `loopback-binding` | Every published port binds `127.0.0.1`, or carries a named exemption with its reason. |
| `overview-sync` | `docs/services.md` has a row for every published port, and a row's pinned tag matches the compose. |
| `fail2ban-journal-contract` | The Authentik compose journald tag and both fail2ban `journalmatch` consumers agree. |
| `vlogs-ingest-contract` | The six couplings of VPS log shipping: sink host and path, stream fields, token name, the token in both examples, and the ingest vhost never forward-authed. |
| `tmpfiles-ownership` | On the full services-VM config: `/srv/komodo` exists 0700 root, and every `/mnt` bind source has a tmpfiles `d` rule (rules #10, #14). |
| `stack-dirs-generated` | `nixos/stack-dirs.nix` byte-matches a re-run of `nixos/generate-stack-dirs.py` (rule #51). |
| `stack-env-drift` | Per stack, `secrets.sops.json`, `secrets.example.env` and the fixture hold the same key set, and none stores a key `env.nix` builds. |
| `host-network-declared` | Every `network_mode:` service is listed with its reason (such services pass port-based checks with an empty set). |
| `backup-coverage` | `backup-prepare.sh` against the stacks, both directions: every dump path is a service-specific mount, every bind source/stack/database engine is backed up or allowlisted by name, and both allowlists are stale-checked (rules #36, #70). |
| `auth-column-parity` | A `docs/services.md` row claiming FwdAuth has a Caddy handle that imports `protected`, matched by port (rule #32). |
| `auth-coverage-required` | Every Caddy vhost is forward-authed, in an OIDC blueprint's redirect URIs, or exempt with a written reason; stale exemptions fail. |
| `gatus-target-coverage` | Every Caddy vhost is probed twice by Gatus: through Caddy with the real `Host:`, and on loopback (rules #15, #27). |
| `headscale-policy` | `policy.hujson` is a policy headscale accepts (it switches the tailnet to default-deny). |
| `komodo-sync-coverage` | Every stack has exactly one `[[stack]]` block in `komodo/sync/stacks.toml`, tagged `gitops`, in the one shape the deploy path relies on — and its `config_files` cover every repo file the compose bind-mounts. |
| `run-sh-suite-parity` | `run.sh`'s named-suite arm and `default.nix`'s `suites` list the same names. |

## What it cannot cover

Do not read a green run as covering these.

| Not covered | Why, and what stands in |
|---|---|
| Let's Encrypt, Cloudflare DNS-01, public DNS | No internet. Pebble exercises Caddy's ACME client over HTTP-01; `/etc/hosts` stands in for DNS; the services-VM suites force `tls internal`. |
| Caddy's cloudflare-dns plugin | `update-images.sh` substitutes upstream `caddy` for the fork image, so a broken fork build fails nothing here. |
| Hetzner and Proxmox provisioning | `nixos-anywhere`, `qmrestore` and the real hardware config are outside the sandbox. `disko` and `proxmox-boot` cover the disk layout and the image's first boot. |
| The production secret values | Need the production key. `sops-declared` and `stack-env-drift` check the real files' key sets. |
| The Storage Box leg of backups and restores | `backrest` snapshots to an in-VM SFTP endpoint and `restore` closes the loop against a local repository; neither touches Hetzner. The manual drill in `docs/deploy.md` ("Backups and the restore drill") is the control for that leg; the full-host procedure is `docs/bring-up.md` Appendix A. |
| An OIDC or forward-auth browser login | Authentik's flow executor is a JS app with enforced TOTP. Blueprint objects, the secret contract, discovery and the unauthenticated redirect are asserted; the first real login per app is a manual post-deploy check. |
| A rotation reaching the provider row | `rotation` stops at the worker environment; `authentik` reads provider rows but never rotates. |
| The VPS → services-VM log hop | `vps` has no services VM, so pushes fail by construction; `victorialogs` proves ingest on the VM side only. Production's Gatus freshness probe is the control. |
| A real fail2ban ban or reputation lockout | The filter and policy logic are asserted; an actual ban would race the later SSH subtests. |
| Egress-dependent behaviour | Metadata and cover providers, Anna's Archive, Profilarr's Dictionarry link, ML models, link scraping, market data, Proton: each suite pins the degraded-but-healthy offline state instead. |
| GPUs, the Coral TPU, cameras, the IoT VLAN | The guarded device stanzas are asserted to exist and to degrade; Frigate's detector is overridden to CPU, so the block that fails hardest in production is not the block under test. |

Where an override costs coverage, `lib/profiles.nix` names the loss and, where
possible, a lint recovers it against the real value.

## Rules learned building it

Each rule below was found by a suite or lint failing, and code across the repo
cites them by number ("finding #14", "ledger #30"). The numbers are stable.

**1. Check a version's defaults, not only the keys you set.** Headscale 0.27
defaults `dns.override_local_dns` to true, and true with no global nameservers
is fatal at start. `modules/headscale.nix` sets it false.

**2. sops-nix extracts per-key values only from yaml and json.**
`sops-install-secrets` treats dotenv like binary: every `/run/secrets/<name>`
would hold the whole decrypted document, with no warning. OS secrets are yaml
and stack secrets json; `sops-dotenv-extraction` guards it.

**3. Tag conventions differ per registry; resolve, never guess.** Some
upstreams tag `v1.2.3`, others `1.2.3`. `update-images.sh` resolves every
reference against its registry and `image-pins` fails on a stale pin. The
self-built Caddy image must be published by `build-caddy.yml` before the
caddy stack can deploy.

**4. Nothing may need the network to boot.** A container that fetches a
package, a driver or a schema at start takes its stack down with the network
and can never pass an offline suite. Inits use what the image ships
(`stacks/backrest/config-init.sh` is busybox-only).

**5. Backrest's `autoInitialize` is fatal only on a never-initialised
repository.** Box unreachable at the first-ever init means a crash loop and no
UI; across a restart of an initialised repo the UI comes up. The `backrest`
suite pins both sides.

**6. Backrest base64-decodes `passwordBcrypt` before comparing.** Store
`base64(bcrypt)`, never a raw bcrypt (sopsgen's `bcrypt_b64` part). The suite
logs in with the fixture credentials.

**7. Authentik discovers blueprints by `**/*.yaml` only.** A `.yml` file is
mounted, readable and silently never applied. The `authentik` suite polls the
applied objects.

**8. Backrest accepts `actionWebhook` and has no handler for it.** Hooks use
`actionShoutrrr` (ntfy) and `actionHealthchecks` (dead-man); the suite fires
them with a real backup.

**9. A comment-only YAML key is `null`, and one `null` aborts a whole
blueprint.** Authentik's importer calls `.items()` on it and rolls back
everything in the file, visible only in the worker log. Each blueprint is
asserted to apply on its own.

**10. A bind-mounted file must be readable by the uid that reads it.** Docker
creates missing sources root-owned, and an unreadable mount fails inside the
container. `/srv/komodo` (Periphery's clone root) is 0700 root because every
clone's `.git/config` carries the bot token; files a non-root container reads
must be world-readable. `tmpfiles-ownership` checks the deployed config.

**11. A missing `env_file` aborts the whole stack.** So a stack with no
secrets declares none, and a stack's env must be rendered by `nrs-vm` before
its first deploy. `env-file-coverage` allows only the paths the host renders.

**12. Forward auth must not traverse the public vhost.** The outpost routes by
`X-Forwarded-Host`, which Caddy replaces unless the caller is a trusted proxy.
The `(protected)` snippet dials the VPS over the tailnet by MagicDNS name and
the VPS Caddy trusts the tailnet range; `forwardauth` asserts both directions.

**13. The embedded outpost needs `authentik_host`.** Without it the
authorize and logout URLs point at `localhost`. `forward-auth.yaml` sets it.

**14. Root-owned is docker's default, not a safe choice.** A non-root image
crash-loops on a bind source docker created root-owned. Every `/mnt` bind
source gets a tmpfiles rule with its real owner, generated by
`nixos/generate-stack-dirs.py` into `nixos/stack-dirs.nix`.

**15. qBittorrent rejects a `Host` whose port differs from its listen port.**
Both the loopback publish and the Caddy vhost get a bare 401. `qbit-init`
seeds `WebUI\HostHeaderValidation=false` (moot behind loopback and Caddy).

**16. A second container from an image inherits its healthcheck.** It probes a
process that container does not run. Override the healthcheck with what the
container actually depends on.

**17. Kavita swallows every failed write to `appsettings.json`.** A read-only
mount keeps the published placeholder JWT key in play with no error. The
config directory is writable and `kavita-config-init` seeds a real key; the
`books` suite re-reads it after start. Kavita also decides "OIDC enabled"
differently on disk and in the DB, so the init blanks the authority whenever
the secret is empty.

**18. Audiobookshelf's headless paths are destructive on bad input.** A
malformed `POST /init` kills the server, an empty password creates a
passwordless root, and an omitted subfolder setting becomes the literal string
`undefined` in the redirect URI. `books-init` guards each; OIDC is asserted
after a restart, since a missing field silently drops it on the next load.

**19. A hook handed its payload on stdin cannot be a `python3 - <<EOF`
script.** The heredoc is stdin. The Shelfmark hook reads stdin first (with a
timeout), is mode 755, and catches `Exception`, because a non-zero exit marks
the download failed.

**20. Configure only outputs that a source can feed.** Shelfmark's audiobook
pipeline has no source under `SEARCH_MODE=direct`, so the stack ships without
it; audiobooks arrive through the media stack's drop folder.

**21. Key-length rules fail late and point elsewhere.** Kavita needs a ≥512-bit
`TokenKey` (`openssl rand -hex 64`), and its register endpoint reports the
failure as the same 400 as "admin exists". `books-init` reports both
hypotheses.

**22. Kavita's `enableMetadata` controls reading metadata inside the file,
not external providers.** Off, a Book library indexes nothing. The external
switches are `allowMetadataMatching` and `allowScrobbling`.

**23. Home Assistant's YAML `mqtt:` block with broker settings is silently
invalid.** HA starts healthy and never connects. `automation-init` creates the
MQTT config entry through the config-flow API; the suite asserts it is loaded
and that Frigate published `online`.

**24. Frigate's proxy role map grants nothing without an explicit
`role_map`.** Without it a user is admin only in a group literally named
`admin`, and `proxy.separator` must match Authentik's `|`.

**25. Name an env key by the application that reads it.** `env_file` injects
names verbatim; a service-prefixed `BOOKSTACK_APP_KEY` leaves `APP_KEY` unset,
and that image then sleeps forever as `running`. Prefix only where the app
itself does.

**26. "No such tag" is a diagnosis only if the registry said so.** A prefetch
fails the same way on a 404, a 5xx, a rate limit or a reset.
`update-images.sh` retries three times and prints the real last error.

**27. A healthcheck that gates `depends_on` is load-bearing for another
container.** Dawarich's probe 301s under `force_ssl`, so Sidekiq never starts;
and its health endpoint is excluded from host authorization, so a wrong
`APPLICATION_HOSTS` is a healthy container serving 403s. Probe `/` with the
real `Host:` (`gatus-target-coverage`), and assert dependents by their own
evidence.

**28. Read the entrypoint before running an image any other way.** A one-off
`rails runner` container skips the entrypoint's `unset BUNDLE_PATH` and finds
no gems.

**29. Soft delete plus a unique index means "deleted" keeps the identity.**
Rename a seeded account rather than destroying it, and assert the seeded
credential is dead — the negative assertion is the one that matters.

**30. Compose interpolates `env_file` values; single-quote every value.**
Bare or double-quoted `$argon2id$v=19$…` loses every `$name` to empty
expansion with no warning. `nixos/modules/stack-env.nix` renders every value
single-quoted; `vaultwarden` and `wealthfolio` prove it with a real login,
because only a round trip distinguishes configured from mangled. `$$`-escaping
applies to inline `environment:`, not to env files.

**31. "Service X authenticates against IdP Y" is a protocol claim.** Check the
protocol path and hash format before promising an integration: SMB cannot
forward a plaintext bind, and an IdP storing PBKDF2 cannot serve a protocol
that needs NT hashes.

**32. An inventory's auth column is a claim that needs a check.**
`auth-column-parity` fails when a FwdAuth row has no protected Caddy handle,
and it keys on the **port**, which appears verbatim in both files — a
heuristic that can miss rows reports success on exactly those rows.

**33. A Laravel `APP_KEY` must decode to exactly 32 bytes.** A wrong length
fails during middleware termination, after the page rendered; only BookStack's
`/status` (database, cache, session) reports it. The `tracking` and `firefly`
suites assert key lengths directly.

**34. `wget --spider` is a HEAD request.** A GET-only route answers 405 and
the container sits unhealthy. Use `wget -q -O /dev/null` unless HEAD is
verified.

**35. MariaDB 11 ships `mariadb-dump`, not `mysqldump`.** The env var keeps
its `MYSQL_` spelling; only the binaries were renamed. Suites run
`backup-prepare.sh`'s literal command.

**36. If one entry matches everything, the check is that entry.** Backrest
mounts `/mnt/fast` wholesale, so "inside some declared mount" passed every
path. `backup-coverage` excludes whole-tier mounts; be suspicious of a lint
that passes on its first run.

**37. An init that has run once has not been tested.** Homebox answers a
duplicate registration with a 500 naming the unique constraint; the init
accepts exactly that body. Every suite re-runs its inits and expects zero
`CHANGE:` lines.

**38. A regex character class `@-_` is a range.** rmfakecloud strips the
hyphen from an email on create but not on login. Enumerate what a whitelist
admits by running it; `notes-sync-init.sh` refuses such an email up front.

**39. `up --wait` fails on a one-shot that exited 0.** It waits for running or
healthy. Name the long-lived services in `up --wait` and wait for one-shots by
exit code.

**40. A container that downloads at start is a crash loop on a tailnet-only
host.** ExcaliDash's entrypoint fetched a Prisma engine for another
architecture on every boot. Only an offline boot finds this.

**41. In a preprocessed file, describe a syntax in words.** Glance substitutes
environment references in the raw text, comments included, and a missing one
is fatal. The same applies to compose (`$`), systemd (`%`) and envsubst.

**42. `up --wait <service>` errors on a named service without a healthcheck.**
Over the whole project it does not. Name only long-lived services that have
healthchecks; assert the rest by their own evidence.

**43. Idempotent in effect is not idempotent in response.** Windmill's delete
returns 2xx whether or not the user existed. Look before mutating and log a
`CHANGE:` only for a real change.

**44. A monitoring agent can report zero instead of an error.** Beszel with a
wrong `FILESYSTEM` logs one WARN, stays healthy and reports a 0 GB disk. The
suite asserts `stats.d > 0` hub-side; the example carries
`findmnt -no SOURCE /`.

**45. `docker run --health-cmd` is always CMD-SHELL.** It cannot probe a
`FROM scratch` image. Compose's `test: ["CMD", …]` list form is exec form and
is fine.

**46. Beszel drops a filesystem whose device name collides.** No log line. The
suite uses two real block devices; on the host, two tiers on one device show
as one.

**47. Give a database data directory its engine's uid.** MySQL and Postgres
drop privileges before initialising and abort on a root-owned directory.
`generate-stack-dirs.py` sets 999 or 70 with mode 0700.

**48. A config value can be required by a branch that never runs.** nginx
parses the whole file, so an unset variable in a dead `map` branch is fatal;
supervisord then keeps the container `Up` while serving nothing. Replace baked
`supervisorctl status` probes with one that fetches through the server.

**49. Beszel prunes a filesystem the same size as root.** Two equal,
equally-full tiers look like duplicates. The suite uses different disk sizes
and asserts the "Ignoring duplicate FS" line is absent; assert `d` (total),
not `du`.

**50. A fixture chosen for convenience can redefine a test.** tmpfs is right
for a writable path and wrong the moment a subtest says "survives a reboot";
those suites use real disks.

**51. A checker whose universe is a hand-list measures the list.** Glob the
universe and hand-write only the judgments: `generate-stack-dirs.py` globs
`stacks/*/compose.yaml`, and `stack-dirs-generated` byte-compares its output.

**52. A file copy of a WAL database is not a backup.** `backup-prepare.sh`
dumps SQLite with `.backup` and Postgres with `pg_dumpall`; `backup-coverage`
makes an omitted engine a failure.

**53. `OnFailure=` fires only when a unit can reach `failed`.** With
`Restart=` and a slow `RestartSec`, the default start limit never trips. Size
`StartLimitIntervalSec`/`StartLimitBurst` so the unit can give up.

**54. `OnUnitInactiveSec=` never elapses on a `RemainAfterExit` oneshot, and
ordering against a nonexistent unit is silently ignored.**
`tailscale-autoconnect` has no `RemainAfterExit`, orders against
`tailscaled.service`, and polls for a terminal backend state.

**55. A default can differ by enrollment path and widen on rename.**
Headscale's node expiry is set explicitly in `modules/headscale.nix`, with
the warning that the 0.28 rename covers preauthkey nodes too.

**56. The Caddyfile is a compiler input; check its output.** `copy_headers`
already deletes what it copies, and `request_header` sorts after
`forward_auth`, so `-X-Authentik-*` lives at site level. Verify with
`caddy adapt`.

**57. Narrowing a bind mount to a single file changes how absence fails.** A
missing source becomes a manufactured directory. `config-init.sh` tests `-f`
before `-s`.

**58. Re-point a pinned host key for a stand-in; never relax it.** The suite
`ssh-keyscan`s its SFTP endpoint into the same `known_hosts` the pin reads.
Hetzner publishes fingerprints, so the committed keys are verified with
`ssh-keygen -l`.

**59. `xcaddy build` without a version builds the latest Caddy.** The
Dockerfile passes the version explicitly; a fully pinned `FROM` is not enough.

**60. A whole-project `up` needs every image preloaded.** A missing one shows
up as a registry error in an unrelated suite; a suite's `stackImages` list is
part of its contract.

**61. Ask who invalidates a secret, and when.** `SIMPLEFIN_TOKEN` is a
one-time claim URL; the durable credential it exchanges for lands outside
sops.

**62. Some env vars are presence-tested.** SilverBullet's `SB_READ_ONLY=false`
turns read-only mode on. Check how the app parses a boolean before
"documenting the default".

**63. An entrypoint that executes a file from a writable volume extends the
attack surface to whoever writes that volume.** SilverBullet runs
`CONTAINER_BOOT.md`; the git-sync sidecar alerts if it appears and does not
delete it.

**64. A version bump can remove the only proof a mitigation is active.**
SilverBullet 2.10 drops the shell-backend log line; the stack stays on 2.9.0
until that proof is re-measured.

**65. Distrust boot-time claims about runtime dependencies.** Outline boots
healthy without an IdP; what fails is logging in, which no healthcheck sees.

**66. `git rebase -X ours` keeps the upstream side and resolves silently.**
The SilverBullet sync saves a superseded local commit on a named branch and
alerts, because git's exit code says nothing.

**67. Whether `npx <cmd>` at start is safe depends on the image's layers.**
Check that the binary and a matching engine are baked in.

**68. An image's HTTP client comes from its base.** `node:*-slim` has `curl`
and no `wget`; alpine has busybox `wget` and no `curl`. Check with
`docker run --rm <image> which curl wget` before writing a healthcheck.

**69. One project's tags can have opposite runtime contracts.** An `edge` tag
that clones and installs at start cannot boot offline. Diff the Dockerfiles.

**70. An unnecessary allowlist entry is as wrong as a missing one.**
`backup-coverage`'s allowlists are stale-checked both ways.

**71. Fail-fast locking suits one operator; many callers need a queue.**
`update-images.sh` refuses a concurrent run (exit 99) rather than interleave
into one tmpfile; concurrent callers should wait their turn, and a lock file
that is unlinked on exit lets a waiter lock a recreated file.

**72. A quarantine `mv` is a rename; hardlinks keep the inode.** `/mnt/slow`
is one filesystem so imports are hardlinks; `scan-downloads.sh` removes every
other path to the infected inode, and the suite asserts the library path is
gone.

**73. qBittorrent's login answers 204 with a `QBT_SID_<port>` cookie.** Accept
204 or `Ok.` and take whatever cookie is issued.

**74. journald's rate limit truncates `docker logs` without a note.** Every
container logs as `docker.service`, one bucket. `rateLimitBurst = 0` ships
with the journald log driver; `journald-logging` measures it.

**75. Alloy's `loki.source.journal` `labels` is overridden by
`relabel_rules`.** Apply static labels as relabel rules, and test with the
query you will actually run.

**76. A journal-reading container needs a path override or the host
machine-id; with neither it reads nothing and stays healthy.** Both are
mounted. Do not mount `/run/log/journal` under persistent storage.

**77. A harness must consume production's source of truth, not re-implement
its defaults.** `mk-stack-suite.nix` reads the generated `stack-dirs.nix` and
fails at eval on a bind source without a rule.

**78. A tag is not a pin; upstreams re-push.** When `image-pins` goes red with
no compose change, re-run `update-images.sh` and read the digest diff.

**79. Suites materialise files from the world-readable Nix store, so they
cannot see file-mode bugs in delivery.** A provisioning file a non-root
container reads must be world-readable where the host delivers it; Grafana
treats an unreadable datasource file as fatal. A crash loop with a
RestartCount in the thousands and `docker events` showing `die`/`start` pairs
is the tell.
