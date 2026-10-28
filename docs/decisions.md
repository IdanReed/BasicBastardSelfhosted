# Decisions

The standing design decisions and the open ones, each with its reason. The IDs
(`D-nn`, `AS-nn`) are stable handles: code comments cite them, so an entry
keeps its ID when it moves between sections. The rule: decide → implement →
move the entry to **Decided** — or delete it once nothing in the repo depends
on the reason.

---

## Decided

### Security

- **AS-5 — Every vhost declares its auth.** The `auth-coverage-required` lint
  requires each `handle @x` in `stacks/caddy/Caddyfile` to be forward-authed
  (`import protected`), in an Authentik OIDC blueprint's `redirect_uris`, or
  listed in `UNAUTHENTICATED_OK` with a written reason. Several apps make the
  first caller to log in the owner, so a new route must not be open by default.
  A stale exemption is an error too.
- **D-04 — Backrest sits behind forward auth** in front of its own bcrypt
  login: it holds the restic password and the VPS backup key. It is a
  browser-only UI; backups and the dead-man ping are outbound calls the gate
  never sees. With Authentik down, reach it on loopback (`ssh -L
  10002:127.0.0.1:10002 idan@10.0.0.3`).
- **AS-8 — Periphery holds every deployed secret.** The age key never enters a
  container (sops-nix renders on the host), but Periphery runs as root and
  reads every `/run/stack-env/<name>.env`. The invariant keeps the *key* out,
  not the plaintext; the docker socket is root on the host either way.
- **D-10 — `akadmin` and `AUTHENTIK_BOOTSTRAP_TOKEN` stay as break-glass.**
  Both persist in Authentik's database and no blueprint retires them; they are
  the way back in when the blueprints or OIDC are broken. Revisit (a blueprint
  deactivating `akadmin`) once no per-app setup step needs the admin UI.
- **D-33 — Vaultwarden `SSO_SIGNUPS_ALLOWED=true`.** The Authentik user list
  is the gate on who gets a vault; `SIGNUPS_ALLOWED=false` never gated SSO
  signups, so an `/admin` invite would be a second gate that buys nothing.
- **D-34 — An Authentik group named exactly `Admin` is a fleet-wide privilege
  handle.** BookStack matches IdP group names against role display names, so
  membership *is* BookStack admin and survives a rebuilt database; the
  admin-only apps bind their application to the same group. Any new app that
  matches group names picks it up — the comment in `headscale-oidc.yaml` says
  so.
- **D-41 — Immich `IMMICH_ALLOW_SETUP` stays unset.** Setting it `false` closes
  a restore endpoint that is loopback-only behind Caddy, and would stop
  `immich-init` re-seeding after a volume wipe — re-seeding is worth more.

### Secrets

- **D-26 — `sopsgen rotate user/idan` rewrites secrets, not logins.**
  Seed-once consumers (qBittorrent's conf, Backrest's `config.json`, Beszel's
  `data.db`, Windmill's account row, Jellyfin's and Cleanuparr's stored admin)
  keep the old value until their seed is reset. `docs/bring-up.md` has the
  per-consumer table; `qbit-init` warns on drift. The guards for the silent
  ones are open below.
- **D-40 — The Firefly importer's PAT is minted by hand.** The only
  `createToken` path is a browser session (`laravel/tinker` is not in the
  image). Passport's RSA pair comes from sops (`freeze: true`), so the token
  survives a container recreate; only a database rebuild needs a new one.

### Stacks

- **D-08 — A sidecar gets the values it reads, not the whole stack env.** Name
  a service's values in `environment:` as `${VAR:-}` (interpolated from the
  rendered env) instead of `env_file:` when it needs only a few — seerr takes
  `API_KEY` alone, `karakeep_meilisearch` takes `MEILI_MASTER_KEY` alone. The
  remaining wide consumers are open below.
- **D-19 — One directory = one deployable stack.** Eight stacks repeat the same
  Postgres block. A shared `extends:` file or a Nix generator would break the
  property Komodo's `run_directory` and the harness's per-compose parsing both
  rely on, for a cosmetic gain.
- **D-29 — `postgis/postgis:17-3.5-alpine` is a moving tag, deliberately.** No
  patch-pinned alpine tag exists; `tests/lib/images.nix` pins the digest, so
  drift shows up as a pin mismatch rather than silently.
- **D-30 — `scan-downloads.sh` scans inside `.incomplete`.** qBittorrent's
  rename to the final path preserves mtime, so a file scanned only there can
  predate the marker and be skipped. An infected partial is quarantined
  mid-download — that fails safe.
- **D-32 — Paperless admin is a manual `/admin` grant.** The superuser-group
  variable exists only from 3.1.0; the pin is 2.20, where it is silently
  ignored. Set it with the next major bump wanted for its own sake, not to
  delete this step.
- **D-35 — Jellyfin keeps its own logins.** TV and mobile clients cannot follow
  an OIDC redirect. The local admin is seeded from sops by `jellyfin-init`
  and stays as break-glass; the other users come from Authentik without
  OIDC. Jellyfin has no headless password reset, so the admin's password
  changes in the Jellyfin UI first (D-26).
- **Actual's OpenID is enabled by `actual-init`**, never by server env (the
  pinned server would go OpenID-only at boot, before a password exists). The
  first OIDC login still becomes the permanent owner, so log in as `idan`
  right after the deploy that enables it.

### Hosts

- **D-42 — The services VM's `10-lan.link` matches both MACs**
  (`a2:db:6f:f6:9f:d7`, VM 110's own, and `bc:24:11:5e:11:03`, the one the
  image carries), so `ens18` exists under either. `docs/bring-up.md` §9's
  `qm set` restores 110's MAC after a re-image.
- **D-44 — tmpfiles rule order follows module merge order,** not the source
  file's; the paths are distinct and `d`-before-`C+` still holds.
- **D-46 / D-47 — Desktop linting.** nixfmt stays non-fatal in
  `nixos-de/test.sh` (adopting it is one standalone mechanical commit);
  `statix.toml` disables `repeated_keys` and `empty_pattern`, because flat
  dotted paths and `{ ... }:` headers are the NixOS idiom.
- **D-55 — Docs use `--use-remote-sudo`**, the spelling the code and the shell
  aliases use. Switch everything at once if nixpkgs drops the alias.

### Tests/CI

- **D-52 — Renovate does not bump the plugin half of the Caddy tag.** The
  `caddy-fork-tag` manager rewrites the Caddy half; a cloudflare-plugin bump
  is a hand edit to the `-cfX.Y.Z` suffix, as the Dockerfile header says.
  Plugin bumps are rare enough.

### Docs

- **D-57 — The README links `docs/services.md`** instead of duplicating its
  service tables. Only the inventory is linted against the compose files; a
  second copy drifts.

---

## Open

### Security

Open security items are tracked privately, outside this public repo.

### Secrets

- **D-23 — `TAILSCALE_AUTH_KEY_OLD`** sits in both hosts' real files, examples
  and three fixtures with no consumer. **Recommendation:** drop it everywhere
  in one change; an unreferenced live preauthkey is worse than a re-mint.
- **D-24 — `WINDMILL_ADMIN_EMAIL` / `WINDMILL_ADMIN_PASSWORD`** are stored,
  unmanaged by the manifest, and read by nothing but a suite assertion.
  **Recommendation:** drop them from the real file, example, fixture and suite
  together.
- **D-26 (guards) / D-37 — Silent seed-once logins.** Backrest's
  `config-init.sh` writes `config.json` once, so a rotated password and any
  plan or retention change in the template never reach a live host; Beszel
  and Windmill keep the old login without a word. **Recommendation:** merge
  `auth.users[].passwordBcrypt` on every Backrest start now, add qbit-init's
  detect-and-warn to Beszel and Windmill, and decide later who owns Backrest's
  plans and retention (repo or UI).
- **Authentik `sub_mode`.** No blueprint sets it, so every user's OIDC `sub`
  hashes the database's `install_id`: a fresh Authentik in front of kept app
  data breaks every app that links by `sub`. Options: keep (Authentik's
  database must survive every cutover) or a deterministic mode such as
  `user_username` (rotates every `sub` once). **Recommendation:** switch only
  when app data is fresh anyway.

### Stacks

- **D-08 (rest) — Wide env consumers.** `gluetun` (`NET_ADMIN`, sees the
  Servarr API keys), `profilarr` (pulls remote definitions) and `frigate`
  (USB device access, sees Home Assistant's credentials) still take the whole
  stack env. **Recommendation:** convert all three to named `${VAR:-}`
  entries, then decide on a lint that allows `env_file` only for listed
  services.
- **D-28 — Paperless starts before its database.** List-form `depends_on` and
  no app healthcheck, so `unhealthy-containers` is blind to it.
  **Recommendation:** `pg_isready`/`redis-cli ping` healthchecks,
  `condition: service_healthy`, an app probe checked against 2.20 (not `/`),
  gated on `./tests/run.sh paperless`.
- **D-39 — Grafana's VictoriaLogs plugin is a host install.**
  `stacks/logging/Dockerfile` and `.github/workflows/build-grafana-vlogs.yml`
  bake it into `ghcr.io/idanreed/grafana-vlogs:<grafana>-vl<plugin>`, but the
  workflow has never run, so the compose pins stock Grafana and the plugin is
  hand-installed under `/mnt/fast/grafana`. **Recommendation:** run the
  workflow once, move the `image:` to the published tag, add the
  `update-images.sh` substitution to stock Grafana for the offline suites, and
  delete the for-shame entry.

### Hosts

- **D-43 — `bootstrap-komodo` sleeps 5 s then `up -d`** with no `--wait`, so a
  failed bring-up does not fail the unit or page. **Recommendation:** `up -d
  --wait` plus `TimeoutStartSec`, landed with a `./tests/run.sh gitops` run.
- **D-45 — `nixos-de/disko.nix` `targetDisk` is `CHANGE_ME_…`.** The committed
  config cannot reproduce the machine, and a wrong value wipes the Windows
  disks. **Recommendation:** fill in the by-id path after confirming the
  serial of the disk that holds `disk-main-root`.
- **D-48 — `headscale/cloud-init.yml`** is superseded, pins `:latest` images,
  and its CoreDNS nameserver is the outage shape `modules/headscale.nix`
  warns about. **Recommendation:** delete it (git keeps it) along with the
  "legacy directories" note that describes it.

### Tests/CI

- **D-20 — The OIDC blueprints are near-identical.** The `*-oidc.yaml` files
  differ only in slug, provider name, `!Env` name, redirect URIs and display text, and
  drift is a silent login break. **Recommendation:** a generator plus
  committed output plus a byte-compare lint (the `stack-dirs` pattern); the
  files must stay on disk for `oidc-contract`.
- **D-21 — No lint reads the firewall**, and the tailnet suite dials 3 of ~45
  listeners from a peer. **Recommendation:** a `firewall-declared` lint and a
  full negative sweep of published ports (Syncthing 22000 first).
- **D-49 / D-50 / D-51 — `update-images.sh` hygiene.** It resolves
  `nix-prefetch-docker` from the flake registry rather than the harness's
  nixpkgs; `images.nix` has no drift lint; its `_unresolved`/`_skipped` lists
  sit beside the pins. **Recommendation:** pin the tool now; reshape the file
  and add the drift lint at the next full regeneration, in one commit.
- **D-53 — The nightly heavy suite fails silently.** **Recommendation:** an
  `if: failure()` step posting to `https://ntfy.svc.idanreed.com/alerts` (it
  gains a token if D-02 lands).
- **D-54 — `.gitignore`'s `*.claude` hides every shared `.claude/` file.**
  **Recommendation:** narrow it to `.claude/settings.local.json` and
  `.claude/worktrees/`, and read `git status --ignored` before the next commit
  so nothing lands unreviewed.

### Docs

- **D-61 — `docs/for-shame.md` and the manifest's `pull` entries are kept by
  hand.** **Recommendation:** a lint that every `class: pull` entry is named in
  `docs/for-shame.md` or `docs/bring-up.md`; generating the page would lose its
  prose.
- **D-62 — `overview-sync` reads only the Port and Image columns of
  `docs/services.md`.** Volume and Auth cells are compared against nothing.
  **Recommendation:** the Volume column first (a restore depends on it), then
  the Auth reverse leg (a row claiming OIDC needs a blueprint, `--` needs an
  `UNAUTHENTICATED_OK` entry).

---

## Accepted risks

- **AS-9 — VictoriaLogs' loopback API is unauthenticated** for `/select/*` and
  `/insert/*`, so any local uid on the services VM (the CI runner's included)
  can read both hosts' journals and write into the store where fail2ban and
  Authentik login evidence lands. The same data is already on the host;
  dropping the publish costs Gatus its probes. D-09's `IPAddressDeny` narrows
  the runner's reach.
- **AS-17 — Syncthing's 22000 is LAN-reachable,** IoT VLAN included: docker
  DNATs before the host firewall sees it. BEP authenticates by device
  certificate first, and every peer is paired from both sides.
- **AS-18 — The cloud-init age key persists in the guest** (the cloud-init
  cache, the attached drive, the Proxmox snippet). Proxmox root is
  root-equivalent on the VM anyway. Clean up with D-01: `qm set <vmid>
  --delete cicustom`, delete the snippet, remove the guest cache.
- **Secrets on argv in two one-shots.** `forgejo-init.sh` passes the OIDC
  secret to `forgejo admin auth add-oauth --secret`, and `syncthing generate`
  takes the GUI password as a flag; neither CLI has a file or env alternative,
  the process is short-lived, and its readers are root-equivalent already.
- **Passwordless sudo for `wheel` and `trusted-users = [ "@wheel" ]`** on both
  servers: a stolen authorized key is root. Deploys over SSH need it; D-06 is
  the targeted narrowing for the one non-human key.
- **VPS journald: `rateLimitBurst = 0` with `SystemMaxUse=512M`.** Log volume
  can rotate ban evidence out; the log shipper moves it off the box first.
- **Declared users' passwords are re-asserted on every blueprint apply,** so a
  password changed in Authentik's UI reverts — change it in
  `secrets/shared.sops.json` instead.
- **DocSpace's portal runs as `user: root`,** following upstream: the
  entrypoint rewrites `/etc/nginx` and its config before supervisord starts.
