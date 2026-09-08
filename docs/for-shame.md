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

For the OIDC deploy mechanics most of these hang off — blueprints, secret twins,
the VPS-first deploy order — see
[`ServerNotes/designs/oidc-rollout.md`](../../ServerNotes/designs/oidc-rollout.md).
That doc is the "how the automated 90% works"; this one is the residual 10%.

Each step is also folded into the bring-up procedure at the point it is needed:
`ServerNotes/designs/deploy-handbook.md` §17. **Host and infrastructure steps**
(the Cloudflare token, the Forgejo runner registration token, the Renovate PAT,
the three Forgejo pubkey pastes, headscale `extra_records`, the Storage Box
sub-account, Samba's LAN-exposure flip) are bring-up steps rather than per-app
chores and live in the handbook, not here.

A note on scope: an *init container* that seeds an admin over the app's own
first-run API (Immich, Mealie, Tandoor, Windmill, Wger, rmfakecloud, qBittorrent,
Karakeep, Homebox, Home Assistant) is **declarative** and is deliberately **not**
on this wall — the whole point of those sidecars is that no human touches the
app. What lands here is the step no init container could take, because the app
offers no non-browser / non-DB path to it.

---

## Summary table

| Service | Manual step | Why not declarative | Survives recreate? |
|---|---|---|---|
| **Beszel** | Set `USER_EMAIL` before the **first** boot | Seeding is declarative, but the PocketBase migration that reads the pair fires only against a virgin `data.db` | Yes — in `data.db` on `/mnt/fast/beszel` |
| **Beszel** | Log in twice (Authentik forward-auth, then Beszel's own login) | OIDC config lives in `users.oauth2` inside `data.db`; no env vars — browser wizard only | n/a (every login) |
| **Jellyfin** | First-run setup wizard: create the first admin and add libraries | No env or config file pre-creates the owner; nothing in the repo drives the wizard yet | Yes — `/mnt/fast/jellyfin/config` |
| **Jellyfin** | (Deferred) install `jellyfin-plugin-sso` for OIDC | No native OIDC; auth plugins are a runtime install | Yes (if ever done) |
| **Seerr** | First-run UI setup (server URL, Jellyfin link, libraries) | Three of the steps are API-only, and nothing in the repo seeds `settings.json` yet | Yes — `/mnt/fast/seerr/config` |
| **Profilarr** | Bind Dictionarry profiles to the arr instances (one UI action) | API-key auth is scoped to `/api/` paths and `/api/v1/arr` is GET-only; the binding is a session-cookie form action | Yes — `/mnt/fast/profilarr/config` |
| **Grafana** | Install `victoriametrics-logs-datasource` by hand on the host | The image that bakes it in is built but never published, so the compose still pins stock Grafana | Yes — `/mnt/fast/grafana/plugins` |
| **Actual** | `docker exec actual node scripts/enable-openid.js`, then log in immediately | OIDC activation is a DB flip with no env equivalent; first OIDC login = permanent owner | Yes — Actual DB |
| **Vaultwarden** | Set a master password in the web vault after the first SSO login | Vaults are client-side E2EE — no server-side seed can create the first vault key | Yes — `db.sqlite3` |
| **Outline** | First login creates and owns the team | No env, no CLI, no seeder in `server/scripts/` | Yes — Outline DB |
| **Homebox** | Close `HBOX_OPTIONS_ALLOW_REGISTRATION` after the first deploy | The open-registration window *is* the headless bootstrap; closing it is a deliberate second act | Yes — compose edit + redeploy |
| **Firefly III** | Mint a Personal Access Token in the UI for the importer | The only `createToken` path is a browser session — `laravel/tinker` is not in the image | Re-minted on every container recreate: Passport's signing keys live on an unpersisted path |
| **Firefly Importer** | Every import is an operator at the importer UI uploading a config JSON | No scheduled sync exists; `SIMPLEFIN_TOKEN` is a one-shot claim URL | No — redone per import |
| **Cleanuparr** | Configure the arr connections and the malware blocker in the web UI | v2 keeps all of it in `/config` SQLite; `cleanuparr.json` covers only `PORT`/`BASE_PATH` | Yes — `/mnt/fast/cleanuparr/config` |
| **qBittorrent** | Rotating the WebUI password needs `qBittorrent.conf` deleted and the stack redeployed | The conf is seed-once: `qbit-init` writes it only when absent, and qbit rewrites it whole on shutdown | Yes — `/mnt/fast/qbittorrent/config` |
| **Bazarr** | Seed the Radarr/Sonarr connections on first login | No env-var path exists, and nothing in the repo seeds the config file yet | Yes — `/mnt/fast/bazarr/config` |
| **Proton / hydroxide** | One interactive `docker exec -it hydroxide … auth <account>` | Env credentials are refused by design so the Proton password never reaches sops; the bridge password prints **once** | Yes — `auth.json` on `/mnt/fast/proton`, but the value must be pasted into `.sops.env` |
| **Syncthing** | Add each peer by device ID, from **both** sides | Deliberate: no device is pre-seeded, so nothing can pair itself | Yes — Syncthing config |
| **SilverBullet** | Create the private Forgejo mirror repo and a `write:repository` PAT, embed both in `GIT_SYNC_REMOTE` | The stack creates neither, by design | Yes — the `.sops.env` value |
| **Excalidraw / Wealthfolio** | OIDC is staged but shipped OFF; enabling it is an operator flip | Both panic or misbehave against an unavailable issuer, so the repo ships them off | One-shot (compose edit) |
| **Audiobookshelf / Dawarich** | Ensure your Authentik email == the seeded admin email **before** the first SSO login | Auto-register matches by email; a mismatch mints a second account to merge | Ordering constraint (one-shot) |
| **Paperless-ngx** | Grant admin/staff in `/admin` if the SSO user needs it | The superuser-group env var first exists in 3.1.0; the compose pins 2.20, where it is silently ignored | Yes — Paperless DB |
| **Samba** | *(not a chore — a why)* users authenticate with a local username/password | Built `--without-ldap --without-ads`, so OIDC/AD is not achievable. Credentials are seeded declaratively | n/a |

---

## Per-service detail

### Beszel — the app login is a *different* collection from the admin console

Two things here.

**(1) Seeding the login you actually use.** PocketBase (Beszel's substrate) has
two account tables. `docker … superuser upsert <email> <password>` — the
documented CLI — creates only a `_superusers` record, the **admin console**
identity. The Beszel **app** login authenticates the separate `users` collection,
which owns systems and drives the dashboard.

The **seeding itself is declarative**: `USER_PASSWORD` is a derived target of
`user/idan`, and the `beszel-role` sidecar PATCHes the seeded row from
`role: "user"` (PocketBase's `InitializeUserRole` default) to `"admin"` once the
hub is healthy. What is not declarative is the *timing*.

- **(b) The step:** set `USER_EMAIL` in `stacks/beszel/.sops.env` before the
  **first** boot (it is `class: config`, hand-set). Recovery on an
  already-initialized DB: patch the existing `users` record's email via the
  superuser API — the migration will not re-fire.
- **(c) Why it is an ordering constraint:** the pair is read **only against a
  virgin `data.db`**, so setting or changing it later is a no-op — including a
  later `sopsgen rotate user/idan`, which rewrites `.env` and leaves the stored
  credential alone. If *only one* of the two is set, Beszel mints a throwaway
  superuser `_@b.b` with a random password and the browser first-run form becomes
  the only way in. Both or neither.
- **(d) Survives recreate:** yes — `data.db` under `/mnt/fast/beszel`. Changing
  the credential means resetting that file.

**(2) Two logins, because OIDC is a browser wizard.**

- **(b) The step:** log in through Authentik forward-auth, then again at Beszel's
  own PocketBase login.
- **(c) Why not declarative:** Beszel's OAuth2 provider config (`clientId`,
  `clientSecret`, `authURL`, …) lives in the `users` collection's `oauth2` options
  **inside `data.db`**, with no environment variable for any part of it.
  Upstream's only documented procedure is a click-path through the PocketBase
  admin UI. `_overview.md` therefore marks the row `FwdAuth` — Caddy forward-auth
  to Authentik **and** Beszel's own login underneath, failing closed either way.
  The **agent** never traverses Caddy (it dials `http://127.0.0.1:10452` on the
  host network), so forward auth is purely a browser concern.
- **(d) Survives recreate:** n/a — it is every login.

### Jellyfin — the setup wizard, and no native OIDC

- **(b) The step:** on first boot, complete the setup wizard, create the first
  admin, and point libraries at `/data/media/*`.
- **(c) Why not declarative:** there is no env var and no config file that
  pre-creates the owner — only the startup state machine does, and the account it
  creates is also what **Seerr authenticates against**, so it is load-bearing
  beyond Jellyfin. The `/Startup/*` and `/Library/VirtualFolders` endpoints *are*
  anonymous while the wizard is open, so an init container could drive them;
  nothing in the repo does yet. Separately, **Jellyfin has no native OIDC** — SSO
  needs `jellyfin-plugin-sso`, a *runtime* plugin install, deliberately parked (a
  runtime download the fleet's no-download rule disallows, and one more moving
  part on a media server).
- **(d) Survives recreate:** yes — `/mnt/fast/jellyfin/config`.

### Seerr — first-run UI setup

- **(b) The step:** first-run UI flow — server URL, Jellyfin account link,
  Radarr/Sonarr connections.
- **(c) Why not declarative:** on the stable tag it authenticates against Jellyfin
  accounts (OIDC lives only in the unreleased `preview-new-oidc` tag). Part of the
  first run is seedable through `settings.json`, but three steps are not — creating
  user 1 (`POST /api/v1/auth/jellyfin`, the only route that does it), the library
  sync-and-enable pair, and `POST /api/v1/settings/initialize`. Nothing in the repo
  seeds or calls any of it yet, and the seed's shape is unforgiving: several
  migrations dereference keys unconditionally and the migrator exits on a throw.
- **(d) Survives recreate:** yes — `/mnt/fast/seerr/config`.

### Profilarr — the arr binding is not reachable over the API

- **(b) The step:** in the Profilarr UI, attach the synced Dictionarry
  quality-profile database to the Radarr/Sonarr instances. `media-init` creates
  the database link and triggers a sync over the REST API; the instance binding
  is a UI action.
- **(c) Why not declarative:** Profilarr's server hooks scope API-key
  authentication to `/api/` paths only, and `/api/v1/arr` is **GET-only** — there
  is no write endpoint to attach instances at all. The only mechanical routes are
  a session cookie driving a SvelteKit form action, a direct DB write, or
  restoring a pre-built config backup; none is a supported interface. The suite
  asserts the *result* (`GET /api/v1/arr` lists both) rather than performing the
  step.
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
  the backend binary non-executable, and Grafana logs "Could not start plugin
  backend" while reporting itself healthy.
- **(c) Why it is still manual:** VictoriaLogs has no Loki-compatible *query*
  API, so a stock Grafana cannot read it without this plugin. The declarative fix
  exists in the repo — `stacks/logging/Dockerfile` bakes the plugin in with
  `grafana cli --pluginUrl <local zip>` (zero network: the installer `os.Stat`s
  the path before any HTTP) and `.github/workflows/build-grafana-vlogs.yml`
  publishes it as `ghcr.io/idanreed/grafana-vlogs:<grafana>-vl<plugin>`, the
  `caddy-cloudflare` pattern. **That workflow has never been run**, so the tag
  does not exist and `stacks/logging/compose.yaml` still pins stock
  `grafana/grafana`. Pointing the compose at an unpublished tag would break every
  deploy, so the host install stays the interim step. Until it runs, Grafana is
  healthy and the provisioned datasource is unusable ("plugin not found"); the
  stopgap is vmui at `http://127.0.0.1:10456/select/vmui/`.
- **(d) Survives recreate:** yes — the plugin dir is inside the
  `/mnt/fast/grafana/plugins` bind.

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
  `ACTUAL_OPENID_ENFORCE=true` (which kills the password fallback) *after* a
  verified login.
- **(d) Survives recreate:** yes — the flip and ownership live in Actual's DB.

### Vaultwarden — the master password, not the account

- **(b) The step:** after the first SSO login, set a master password in the web
  vault. That is the whole step.
- **(c) Why not declarative:** Bitwarden vaults are **client-side E2EE**. The
  account row itself is created by the SSO login — `SSO_SIGNUPS_ALLOWED=true` is
  written explicitly in the compose, and it is not gated by
  `SIGNUPS_ALLOWED=false` — but the vault key is derived in the browser from a
  password the server never sees, so no server-side seed can ever create the first
  vault. There is **no `/admin` invite step**: that was the redundant half.
  `SIGNUPS_ALLOWED=false` stays off by design (local self-registration), and
  master-password login remains a fallback (`SSO_ONLY` unset).
- **(d) Survives recreate:** yes — `db.sqlite3`.

### Outline — first login creates and owns the team

- **(b) The step:** log in once, from the right identity. That login creates the
  team and makes the identity its owner.
- **(c) Why not declarative:** Outline exposes no env var, no CLI and no seeder in
  `server/scripts/` for team creation. On a shared tailnet "whoever clicks first"
  is every enrolled device, so treat it as a deliberate operator action.
  Outline additionally has **no local accounts at all** — its OIDC client secret
  *is* the login, so the twin must be correct before anyone can get in.
- **(d) Survives recreate:** yes — Outline's DB.

### Homebox — closing registration

- **(b) The step:** after the first deploy, set
  `HBOX_OPTIONS_ALLOW_REGISTRATION=false` in `stacks/tracking/compose.yaml` and
  redeploy.
- **(c) Why not declarative:** the *owner* is seeded declaratively —
  `tracking-init.sh` registers `HOMEBOX_ADMIN_EMAIL` with an empty group token,
  and the first user created is the owner with no promotion step. What is not
  declarative is the **window**: registration must be open for that bootstrap to
  work, so closing it is necessarily a second, later act.
- **(d) Survives recreate:** yes — it is a compose value once changed.

### Firefly III — mint a Personal Access Token by hand

- **(b) The step:** in the Firefly UI (*Profile → OAuth*), mint a Personal Access
  Token and paste it into `stacks/firefly/.sops.env` as
  `FIREFLY_III_ACCESS_TOKEN` for the data importer. Never set
  `FIREFLY_III_CLIENT_ID` — the OAuth client is likewise minted by hand.
- **(c) Why not declarative:** the only `createToken` call in the image sits
  behind a browser session (`OAuthController`), and there is no CLI route to it —
  `laravel/tinker` is not a dependency of Firefly III (it appears in
  `composer.lock` only as a `suggest` string, and `psy/psysh` is absent), so the
  usual `artisan tinker --execute` trick does not exist here. The importer's UI
  loads with the token unset but cannot talk to Firefly until it is set.
- **(d) Survives recreate:** the token row persists in Firefly's DB, but Passport
  signs it with an RSA pair under `storage/`, which is **not** a persisted path —
  so every container recreate mints a new pair and silently invalidates the token,
  and the importer starts 401ing with nothing said at deploy time. Re-mint and
  re-paste after a recreate until the keys come from sops.

### Firefly Importer — every import is a human at the UI

- **(b) The step:** open the importer, upload the import-configuration JSON, run
  the import. Repeat per import.
- **(c) Why not declarative:** the importer ships **no scheduled sync** — there is
  no cron, no daemon mode, nothing to configure. `SIMPLEFIN_TOKEN` compounds it:
  it is a one-shot claim URL that the SimpleFIN Bridge invalidates on first use,
  and the durable credential it exchanges for lands in a plaintext JSON on the
  operator's machine.
- **(d) Redone every time:** the import configuration is not stored server-side.

### Cleanuparr — v2 is configured entirely through its web UI

- **(b) The step:** in the Cleanuparr UI, add the Radarr/Sonarr/qBittorrent
  connections and configure the malware blocker against the local blocklist under
  `/config`.
- **(c) Why not declarative:** v2 moved configuration out of environment variables
  into a SQLite database under `/config`. The only env knobs left are `PORT` and
  `BASE_PATH`; every connection, schedule and rule is UI-only, with no import
  endpoint and no config file to seed.
- **(d) Survives recreate:** yes — `/mnt/fast/cleanuparr/config`.

### qBittorrent — the WebUI password is seed-once

- **(b) The step:** after `sopsgen rotate user/idan`, on the services VM:
  ```bash
  docker compose -p media stop qbittorrent
  rm /mnt/fast/qbittorrent/config/qBittorrent/qBittorrent.conf
  ./deploy media        # qbit-init re-seeds the conf from the new .env
  ```
- **(c) Why not declarative:** `qbit-init` seeds `qBittorrent.conf` **only when
  absent**, because qBittorrent rewrites that file whole on shutdown — an
  in-place repair would be overwritten by the very container it is repairing, and
  `up -d` recreates the init oneshot *before* stopping qbit. So a rotated
  `WebUI\Password_PBKDF2` in `.env` never reaches the running server.
  `qbit-init` compares the stored hash against `.env` and emits four WARN lines
  naming the cause and this repair, so the drift is loud rather than silent — but
  the repair itself is manual.
- **(d) Survives recreate:** yes — the conf is on `/mnt/fast/qbittorrent/config`,
  which is exactly why the stale value survives too.

### Bazarr — arr connections on first login

- **(b) The step:** on first login, add the Radarr and Sonarr connections
  (address, port, API key) in Bazarr's settings.
- **(c) Why not declarative:** Bazarr has no env-var path for provider or arr
  configuration. The seedable file is `<config>/config/config.yaml` — the doubled
  `config` is where Dynaconf looks, and a partial file is correct because the
  validators fill the rest — but nothing in the repo writes it yet, so the values
  come from the UI on first login.
- **(d) Survives recreate:** yes — `/mnt/fast/bazarr/config`.

### Proton / hydroxide — the only interactive login in the fleet

- **(b) The step, once per re-keyed volume:**
  ```bash
  docker exec -it hydroxide /app/hydroxide auth idan@idanreed.com
  #   ... prints "Bridge password: <base64>" — shown ONCE, save it NOW
  sopsedit stacks/proton/.sops.env      # PROTON_BRIDGE_PASSWORD, PROTON_ACCOUNT
  docker restart proton_export
  docker exec proton_export /sync       # first export on demand
  ```
- **(c) Why not declarative:** this is deliberate, not an upstream gap. hydroxide
  refuses environment credentials so the Proton account password never reaches
  sops; the container consumes **no environment at all**. The bridge password it
  prints is the key that decrypts `auth.json`, is stored nowhere else, and is
  displayed exactly once — so the volume alone is useless and `.sops.env` alone is
  useless. It is the only step in the fleet that requires a TTY.
- **(d) Survives recreate:** yes — `auth.json` under `/mnt/fast/proton`, but the
  bridge password must be captured into `.sops.env` at the moment it is printed.

### Syncthing — peers are paired from both sides, on purpose

- **(b) The step:** add each peer by device ID in the Syncthing UI, and accept it
  on the other device.
- **(c) Why not declarative:** deliberate. No device is pre-seeded, so there is
  nothing for either end to trust ahead of time; pairing is the trust
  establishment. Automating it would mean shipping a device ID and an
  auto-accept, which is the property the design is avoiding.
- **(d) Survives recreate:** yes — Syncthing's config volume.

### SilverBullet — the git mirror is not created for you

- **(b) The step:** create a private Forgejo repository, mint a
  `write:repository` PAT, and embed both in `GIT_SYNC_REMOTE` in
  `stacks/silverbullet/.sops.env`.
- **(c) Why not declarative:** the stack deliberately creates neither the repo nor
  the token — a write-scoped credential that a container could mint for itself
  would be a credential a compromised container could mint for itself.
- **(d) Survives recreate:** yes — it is a sops value.

### Excalidraw / Wealthfolio — OIDC staged, shipped OFF

- **(b) The step:** flip the OIDC env on in the compose file once you have
  verified the issuer is reachable. For Excalidraw, put your Authentik email into
  `SUPERADMIN_EMAILS` **before** enabling — super-admin is matched by email at
  login, and enabling first loses it.
- **(c) Why not declarative:** both ship off because discovery failure is fatal
  rather than degraded — turning them on makes every restart hostage to VPS
  reachability. The client secrets exist; only the flip is manual, and it is a
  judgement call rather than a chore.
- **(d) One-shot:** a compose edit.

### Audiobookshelf / Dawarich — email must match the seeded admin

- **(b) The step:** before your first SSO login, ensure your **Authentik email
  equals the seeded local admin's email** (`DAWARICH_ADMIN_EMAIL` for Dawarich;
  the seeded local admin for Audiobookshelf).
- **(c) Why not declarative:** auto-register matches by email. A mismatch is not
  an error — it silently mints a *second* account you then have to merge. The
  seeding is declarative; the email parity is an operator ordering constraint.
- **(d) One-shot:** effectively an ordering act at first login; a break-glass local
  login exists (ABS: `…/login/?autoLaunch=0`).

### Paperless-ngx — grant staff/admin if needed

- **(b) The step:** in `/admin`, grant admin/staff to the SSO user if it needs more
  than a plain account. Local self-registration stays closed.
- **(c) Why not declarative:** `PAPERLESS_SOCIAL_AUTO_SIGNUP` creates a plain
  user, and role elevation has no env knob at the pinned tag. The variable that
  would do it, `PAPERLESS_SOCIAL_ACCOUNT_SYNC_SUPERUSER_GROUP`, first appears
  upstream in **3.1.0**; the compose pins **2.20**, where it is silently ignored.
  `PAPERLESS_SOCIAL_ACCOUNT_SYNC_GROUPS` is not a substitute — it sets Django
  group membership only, which grants neither `is_superuser` nor `is_staff`. This
  is an image-bump decision, not a config change.
- **(d) Survives recreate:** yes — Paperless's DB.

### Samba — why there's a manual login at all

This row is a *why*, not a chore: credentials are seeded declaratively by
`samba-init.sh` from `.sops.env` on every deploy, and the passwords themselves
come from `sopsgen rotate user/<name>`. It is recorded here so the `Local` auth
cell on the Samba row has an explanation.

- **(c) Why not SSO:** the nixpkgs Samba is built `--without-ldap --without-ads`,
  so OIDC/AD integration is **not achievable**. Exposure is tailnet-only.
- **(d) Survives recreate:** yes — re-seeded from `.sops.env` on every deploy.

---

## The "first login = owner" family (a recurring shape)

Two apps make **whoever logs in first** the permanent owner/admin, with no
declarative way to designate it: **Actual** and **Outline**. Where OIDC
auto-register is on and matches by email, the "manual step" collapses to *log in
first, from the right identity* — but on a shared tailnet "whoever clicks first"
is every enrolled device, so treat the first login as a deliberate operator
action. See `oidc-rollout.md` for the per-app match-by (`email` vs `sub`) details.

Two apps look like members of this family and are not:

- **Homebox** — the owner is pre-created by `tracking-init.sh`; the residual step
  is closing registration afterwards.
- **BookStack** — admin now comes from group membership, re-asserted on every
  login: `OIDC_USER_TO_GROUPS=true` + `OIDC_GROUPS_CLAIM=groups`, and BookStack's
  group sync matches an IdP group name against each role's `display_name`, so an
  Authentik group named exactly **`Admin`** *is* BookStack admin. It survives a
  rebuilt MySQL volume. The coupling is worth knowing: that group name is a
  fleet-wide privilege handle, declared in
  `headscale-vps/authentik/blueprints/custom/headscale-oidc.yaml`, and any future
  app doing display-name group matching will pick it up.

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

Before adding: confirm the step truly has no declarative path (an init container
over the app's first-run API is *not* a wall-of-shame item — it's the fix). If
you find a declarative path for an existing entry, **delete the entry** and note
the mechanism in the stack's `compose.yaml` header instead.

`secrets-gen/manifest.yaml`'s `class: pull` entries are the machine-checked
half of this inventory — every secret that has to be obtained by hand. Keep the
two consistent; where a pull-class secret implies a UI step, the step belongs
here or in the handbook.
