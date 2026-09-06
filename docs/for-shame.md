# The Wall of Shame — manual, non-declarative bring-up steps

Declarative-first is the goal of this fleet: every service should come up from
the repo — compose + `.sops.env` + init containers — with no human clicking
through a browser, no `docker exec` into a running container, and no state that
lives only in a database nobody can regenerate. Most stacks hit that bar. This
document is the honest inventory of the ones that **can't**, and exactly where
the app itself makes it impossible.

Each entry records:

- **(a)** the service/stack,
- **(b)** the exact step — UI path, CLI command, or API call,
- **(c)** *why* it can't be declarative (the app's limitation, not ours), and
- **(d)** whether it **survives a container recreate** (persistent-DB one-shot,
  redone only on volume loss) or must be **redone every time** the volume is
  lost / the OS is re-imaged.

For the OIDC deploy mechanics that most of these entries hang off — blueprints,
secret twins, the VPS-first deploy order — see
[`ServerNotes/designs/oidc-rollout.md`](../../ServerNotes/designs/oidc-rollout.md).
That doc is the "how the automated 90% works"; this one is the residual 10%.

A note on scope: an *init container* that seeds an admin over the app's own
first-run API (Immich, Mealie, Tandoor, Windmill, Wger, rmfakecloud, qBittorrent,
Karakeep, Homebox) is **declarative** and is deliberately **not** on this wall —
the whole point of those sidecars is that no human touches the app. What lands
here is the step no init container could take, because the app offers no
non-browser / non-DB path to it.

---

## Summary table

| Service | Manual step | Why not declarative | Survives recreate? |
|---|---|---|---|
| **Beszel** | App-login user must be seeded (`USER_EMAIL`/`USER_PASSWORD` on first boot, or patch the `users` record) | `superuser upsert` only creates a `_superusers` (admin-console) row; the app authenticates the separate `users` collection | Yes — in `data.db` on `/mnt/fast/beszel` |
| **Beszel** | Log in twice (Authentik forward-auth, then Beszel's own login) | OIDC config lives in `users.oauth2` inside `data.db`; no env vars — browser wizard only | n/a (every login) |
| **Jellyfin** | First-run setup wizard: create the first admin (e.g. `idan`) | No env/API to pre-create the owner without driving the wizard; also the account Seerr authenticates against | Yes — `/mnt/fast/jellyfin/config` |
| **Jellyfin** | (Deferred) install `jellyfin-plugin-sso` for OIDC | No native OIDC; auth plugins are a runtime install | Yes (if ever done) |
| **Seerr** | First-run UI setup (server URL, Jellyfin link, libraries) | Which `settings.json` fields survive first-boot migration is unverified; no blessed headless seed on the stable tag | Yes — `/mnt/fast/seerr/config` |
| **Profilarr** | Bind Dictionarry profiles to the arr instances (one UI action) | Public API v1 exposes only `GET /arr` (read-only); no write endpoint to attach instances | Yes — `/mnt/fast/profilarr/config` |
| **Grafana** | Install `victoriametrics-logs-datasource` plugin by hand on the host | Every hands-off install path downloads at container-create, which the no-runtime-downloads rule forbids | Yes — `/mnt/fast/grafana/plugins` |
| **Kavita** | Toggle `Provision Accounts` in the admin UI | It's a DB field with no env/config knob | Yes — Kavita DB |
| **Actual** | `docker exec actual node scripts/enable-openid.js`, then log in immediately | OIDC activation is a DB flip with no env equivalent; first OIDC login = permanent owner | Yes — Actual DB |
| **BookStack** | Promote the first OIDC user to admin in the UI | New OIDC users link by `sub` and land with the default registration role | Yes — MySQL |
| **Vaultwarden** | Log into `/admin`, invite yourself, register from the web vault | Vaults are client-side E2EE; SSO can only *link* an existing account, never create the first vault | Yes — `db.sqlite3` |
| **Homebox** | First OIDC login becomes the group owner | Owner is whoever logs in first; not assignable ahead of time | Yes — Homebox DB |
| **Firefly III** | Mint a Personal Access Token in the UI for the importer | No CLI and no API path to the token; also the OAuth client must be minted by hand | Yes — Firefly DB (token), but token value must be pasted into `.sops.env` |
| **Home Assistant** | First-run onboarding: create the owner account | Onboarding is browser-only; no headless seed | Yes — `/mnt/fast/homeassistant` |
| **Audiobookshelf / Dawarich** | Ensure your Authentik email == the seeded admin email **before** first SSO login | Auto-register matches by email; a mismatch mints a second account to merge | Ordering constraint (one-shot) |
| **Paperless-ngx** | Grant admin/staff in `/admin` if the SSO user needs it | `SOCIAL_AUTO_SIGNUP` creates a plain user; role elevation is a UI/DB act | Yes — Paperless DB |
| **Samba** | Users authenticate with local username/password (no SSO) | Built `--without-ldap --without-ads`; OIDC not achievable | n/a (why a manual login exists at all) |

---

## Per-service detail

### Beszel — the app login is a *different* collection from the admin console

Two things here, both irreducible.

**(1) Seeding the login you actually use.** PocketBase (Beszel's substrate) has
two account tables. `docker … superuser upsert <email> <password>` — the
documented CLI — creates only a `_superusers` record, the **admin console**
identity. The Beszel **app** login authenticates the separate `users`
collection, which owns systems and drives the dashboard. So `superuser upsert`
alone gives you a working admin console and *no way to log into the app*
(verified live this session).

- **(b) The step:** set **both** `USER_EMAIL` and `USER_PASSWORD` in
  `stacks/beszel/.sops.env` before the first boot — a one-shot PocketBase
  migration reads them and creates the matching `users` record. Recovery on an
  already-initialized DB: patch the existing `users` record's email via the
  superuser API (the migration will not re-fire).
- **(c) Why not declarative-clean:** the env vars work **only against a virgin
  `data.db`** — setting or changing them later is a no-op. Worse, if *only one*
  of the pair is set, Beszel mints a throwaway superuser `_@b.b` with a random
  password and the browser first-run form becomes the only way in. Set both or
  neither.
- **(d) Survives recreate:** yes — the account lives in `data.db` under
  `/mnt/fast/beszel`. Lost only on volume loss, at which point re-seeding
  requires a fresh `data.db` for the migration to fire again.

**(2) Two logins, because OIDC is a browser wizard.** Beszel's OAuth2 provider
config (`clientId`, `clientSecret`, `authURL`, …) lives in the `users`
collection's `oauth2` options **inside `data.db`**, with no environment variable
for any part of it. Upstream's only documented procedure is a click-path through
the PocketBase admin UI. So OIDC is **not achievable declaratively**, and
`_overview.md` marks the row `FwdAuth`: access is gated by Caddy forward-auth to
Authentik **and** Beszel's own PocketBase login sits underneath (fails closed
either way). The cost is two logins on the browser surface. The **agent** never
traverses Caddy — it dials `http://127.0.0.1:10452` on the host network — so
forward auth is purely a browser concern (see `stacks/caddy/Caddyfile` @beszel).

### Jellyfin — the setup wizard is unavoidable, and there's no native OIDC

- **(b) The step:** on first boot, complete the setup wizard and create the
  first admin user (e.g. `idan`); point libraries at `/data/media/*`. Verified
  live this session. `media-init` can drive the `/Startup/*` endpoints, but the
  admin account created here is also what **Seerr authenticates against**, so it
  is load-bearing beyond Jellyfin itself.
- **(c) Why not declarative:** there is no env/API to pre-create the owner
  without stepping the startup state machine, and **Jellyfin has no native
  OIDC** — SSO requires `jellyfin-plugin-sso`, a *runtime* plugin install, which
  is deliberately parked (a runtime download the fleet's no-download rule
  disallows, and one more moving part on a media server).
- **(d) Survives recreate:** yes — `/mnt/fast/jellyfin/config`. Redone only on
  volume loss.

### Seerr — first-run UI setup

- **(b) The step:** first-run UI flow — server URL, Jellyfin account link,
  Radarr/Sonarr connections.
- **(c) Why not declarative:** on the stable tag it authenticates against
  Jellyfin accounts (no OIDC — OIDC lives only in the unreleased
  `preview-new-oidc` tag), and which `settings.json` fields survive the
  first-boot migration on 3.4.x is unverified, so there is no trustworthy
  headless seed.
- **(d) Survives recreate:** yes — `/mnt/fast/seerr/config`.

### Profilarr — the one documented manual UI step in the media stack

- **(b) The step:** in the Profilarr UI, attach the synced Dictionarry
  quality-profile database to the Radarr/Sonarr instances. `media-init` can
  create the database link and trigger a sync over the REST API, but the
  instance binding is a UI action.
- **(c) Why not declarative:** public API v1 exposes only `GET /api/v1/arr`
  (list, read-only). There is no write endpoint to attach instances; the
  candidate workaround (restore a pre-built config backup via
  `POST /api/v1/backups/upload`) is unverified against v2.2.0. The suite asserts
  the *result* (`GET /api/v1/arr` lists both) rather than performing the step.
- **(d) Survives recreate:** yes — `/mnt/fast/profilarr/config`.

### Grafana — the VictoriaLogs datasource plugin

- **(b) The step (once, on the host):**
  ```bash
  curl -fL -o /tmp/vl-ds.zip \
    https://grafana.com/api/plugins/victoriametrics-logs-datasource/versions/0.31.0/download
  mkdir -p /mnt/fast/grafana/plugins
  unzip /tmp/vl-ds.zip -d /mnt/fast/grafana/plugins
  chmod +x /mnt/fast/grafana/plugins/victoriametrics-logs-datasource/victoriametrics_logs_backend_plugin_*
  docker restart grafana
  ```
  The `chmod +x` is load-bearing: an extractor that drops permission bits leaves
  the backend binary non-executable and Grafana logs "Could not start plugin
  backend" while reporting itself healthy.
- **(c) Why not declarative:** VictoriaLogs has no Loki-compatible *query* API,
  so a stock Grafana can't read it without this plugin — and every hands-off
  install path (`GF_INSTALL_PLUGINS` and its preinstall successor) **downloads
  at container-create**, which the offline test VMs and the fleet's
  no-runtime-downloads rule forbid. Until the step runs, Grafana is healthy but
  the provisioned datasource is unusable ("plugin not found"); the stopgap is
  vmui at `http://127.0.0.1:10456/select/vmui/`.
- **(d) Survives recreate:** yes — Grafana's plugin dir is
  `/var/lib/grafana/plugins`, inside the `/mnt/fast/grafana/plugins` bind, so it
  persists across redeploys. Redone only on volume loss.

### Kavita — the `Provision Accounts` toggle

- **(b) The step:** Kavita admin UI → *Settings → Users / OIDC* → enable
  `Provision Accounts` (and default roles).
- **(c) Why not declarative:** these are database fields with **no env or
  config-file knob** and no blessed API seed. This is the single genuine "manual
  UI work" item in the OIDC rollout — every other app's auto-provision is
  declarative. Until the toggle is on, OIDC login works but new users are not
  auto-created.
- **(d) Survives recreate:** yes — stored in Kavita's DB.

### Actual — DB flip plus first-login-owner

- **(b) The step:**
  ```bash
  docker exec actual node scripts/enable-openid.js
  ```
  then log in through Authentik **immediately**.
- **(c) Why not declarative:** the `ACTUAL_OPENID_*` env is present but inert;
  activation is a DB mutation with no declarative equivalent. And the first OIDC
  login becomes the server **owner permanently** (not reassignable from the UI) —
  on the tailnet that is "whoever clicks first". Only set
  `ACTUAL_OPENID_ENFORCE=true` (kills password fallback) *after* a verified
  login.
- **(d) Survives recreate:** yes — the flip and ownership live in Actual's DB.

### BookStack — promote yourself after first OIDC login

- **(b) The step:** after the first OIDC login, promote yourself to admin in the
  BookStack UI. Deploy the **VPS blueprint first** (lockout risk — `AUTH_METHOD=oidc`
  removes the local login form entirely).
- **(c) Why not declarative:** OIDC auto-registration is built-in and
  unconditional, but new users link by the **`sub`** claim (not email) and land
  with the default registration role. There is no env to grant the first user
  admin. (Note: the *initial* admin account itself is created declaratively by
  an `artisan` command in an init container — that part is not on this wall; the
  promotion of the OIDC identity is.)
- **(d) Survives recreate:** yes — MySQL.

### Vaultwarden — invite yourself via `/admin`

- **(b) The step:** log into `/admin` with `ADMIN_TOKEN`, invite yourself,
  register from the web vault. SSO then links to that account by email.
- **(c) Why not declarative:** Bitwarden vaults are client-side E2EE, so SSO
  **cannot auto-create** a first vault — a brand-new vault still needs client
  registration. `SIGNUPS_ALLOWED` stays `false` by design; master-password login
  remains a fallback (`SSO_ONLY` off).
- **(d) Survives recreate:** yes — `db.sqlite3`.

### Homebox — first login is the group owner

- **(b) The step:** the first OIDC login becomes the group owner; close
  `HBOX_OPTIONS_ALLOW_REGISTRATION` afterward if desired.
- **(c) Why not declarative:** ownership is assigned at first login, not
  configurable ahead of time.
- **(d) Survives recreate:** yes — Homebox DB.

### Firefly III — mint a Personal Access Token by hand

- **(b) The step:** in the Firefly UI (*Profile → OAuth*), mint a Personal
  Access Token and paste it into `stacks/firefly/.sops.env` as
  `FIREFLY_III_ACCESS_TOKEN` for the data importer. Separately, never set
  `FIREFLY_III_CLIENT_ID` — the OAuth client is likewise minted by hand.
- **(c) Why not declarative:** there is **no CLI and no API path** to the token —
  it can only be created through the browser after an account exists. The
  importer's UI loads with the token unset but cannot talk to Firefly until it
  is set.
- **(d) Survives recreate:** the token persists in Firefly's DB, but its value
  must be captured into `.sops.env`; on a DB rebuild it must be re-minted and
  re-pasted.

### Home Assistant — onboarding wizard

- **(b) The step:** complete first-run onboarding and create the owner account.
- **(c) Why not declarative:** onboarding is browser-only with no headless seed.
  (HA runs as root with no PUID/PGID and stores everything as UI/YAML state under
  its config dir.)
- **(d) Survives recreate:** yes — `/mnt/fast/homeassistant`.

### Audiobookshelf / Dawarich — email must match the seeded admin

- **(b) The step:** before your first SSO login, ensure your **Authentik email
  equals the seeded local admin's email** (`DAWARICH_ADMIN_EMAIL` for Dawarich;
  the seeded local admin for Audiobookshelf).
- **(c) Why not declarative:** auto-register matches by email. A mismatch is not
  an error — it silently mints a *second* account you then have to merge. The
  seeding is declarative; the email-parity is an operator ordering constraint.
- **(d) One-shot:** effectively an ordering/timing act at first login;
  break-glass local login exists (ABS:
  `…/login/?autoLaunch=0`).

### Paperless-ngx — grant staff/admin if needed

- **(b) The step:** in `/admin`, grant admin/staff to the SSO user if it needs
  more than a plain account. Local self-registration stays closed.
- **(c) Why not declarative:** `PAPERLESS_SOCIAL_AUTO_SIGNUP` creates a plain
  user; role elevation is a UI/DB act with no env knob.
- **(d) Survives recreate:** yes — Paperless DB.

### Samba — why there's a manual login at all

- **(b) The step:** users authenticate with a local Samba username/password;
  there is no SSO.
- **(c) Why not declarative (as OIDC):** the nixpkgs Samba is built
  `--without-ldap --without-ads`, so OIDC/AD integration is **not achievable**.
  Credentials themselves are seeded declaratively (`samba-init.sh` from
  `.sops.env`), so this is not a bring-up chore — it is here to record *why* a
  manual login exists on this row when the fleet standard is SSO. Exposure is
  tailnet-only.
- **(d) Survives recreate:** yes — credentials re-seeded from `.sops.env` on
  every deploy.

---

## The "first login = owner" family (a recurring shape)

Several apps make **whoever logs in first** the permanent owner/admin, with no
declarative way to designate it: **Actual**, **Homebox**, **BookStack**, and
**Outline** (first login creates and owns the team). Where OIDC auto-register is
on and matches by email, the "manual step" collapses to *log in first, from the
right identity* — but on a shared tailnet "whoever clicks first" is every
enrolled device, so treat the first login as a deliberate operator action, not
an afterthought. See `oidc-rollout.md` for the per-app match-by (`email` vs
`sub`) details.

---

## Template for adding a new entry

When a new stack lands with an irreducible manual step, add a row to the summary
table **and** a detail block below, using this shape:

```markdown
### <Service> — <one-line what-and-why>

- **(b) The step:** <exact UI path / CLI command / API call — copy-pasteable>.
- **(c) Why not declarative:** <the app's specific limitation — no env knob,
  browser-only wizard, DB-only field, E2EE, first-login-owner, runtime plugin,
  etc. Name the mechanism, don't hand-wave>.
- **(d) Survives recreate:** <Yes — persistent volume/DB path> OR
  <No — must be redone on every recreate> OR <One-shot ordering constraint>.
```

Before adding: confirm the step truly has no declarative path (an init
container over the app's first-run API is *not* a wall-of-shame item — it's the
fix). If you find a declarative path for an existing entry, **delete the entry**
and note the mechanism in the stack's `compose.yaml` header instead.
