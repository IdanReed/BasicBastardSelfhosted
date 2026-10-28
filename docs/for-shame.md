# The Wall of Shame — manual, non-declarative bring-up steps

Declarative-first is the goal of this fleet: every service should come up from
the repo — compose + `secrets.sops.json` + init containers — with no human clicking
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
| **Forgejo → Komodo** | Create the `komodo` bot (read collaborator on the repo), mint its `read:repository` PAT into `komodo/secrets.sops.json`, add the repo's push webhook | The bot, its token and the webhook live in Forgejo's DB; a token can only be minted once Forgejo runs, and Forgejo has no declarative webhook config | Yes — Forgejo DB + the sops value |
| **Beszel** | Set `USER_EMAIL` before the **first** boot | Seeding is declarative, but the PocketBase migration that reads the pair fires only against a virgin `data.db` | Yes — in `data.db` on `/mnt/fast/beszel` |
| **Jellyfin** | *(not a chore — a why)* no OIDC: each user has a local account with their Authentik username and password | TV and mobile clients cannot follow an OIDC redirect. `jellyfin-init` seeds and re-asserts the accounts | Yes — `/mnt/fast/jellyfin/config` |
| **Komodo** | After your first "Login with OIDC", enable `idan` and make it Admin, logged in as the local `admin` | OIDC sign-ups land disabled on purpose (`KOMODO_ENABLE_NEW_USERS=false`): the UI is root-equivalent, so no account is live until the admin says so | Yes — Komodo DB |
| **Profilarr** | Bind Dictionarry profiles to the arr instances (one UI action) | API-key auth is scoped to `/api/` paths and `/api/v1/arr` is GET-only; the binding is a session-cookie form action | Yes — `/mnt/fast/profilarr/config` |
| **Grafana** | Install `victoriametrics-logs-datasource` by hand on the host | The image that bakes it in is built but never published, so the compose still pins stock Grafana | Yes — `/mnt/fast/grafana/plugins` |
| **Actual** | Be the first OIDC login (it also asks once for the server password) | `actual-init` enables OpenID declaratively, but the first OIDC login becomes the permanent owner and upstream cannot pre-assign it | Yes — Actual DB |
| **Vaultwarden** | Set a master password in the web vault after the first SSO login | Vaults are client-side E2EE — no server-side seed can create the first vault key | Yes — `db.sqlite3` |
| **Outline** | First login creates and owns the team | No env, no CLI, no seeder in `server/scripts/` | Yes — Outline DB |
| **Homebox** | Close `HBOX_OPTIONS_ALLOW_REGISTRATION` after the first deploy | The open-registration window *is* the headless bootstrap; closing it is a deliberate second act | Yes — compose edit + redeploy |
| **Firefly III** | Mint a Personal Access Token in the UI for the importer | The only `createToken` path is a browser session — `laravel/tinker` is not in the image | Yes — the token survives a recreate now that Passport's keys come from sops |
| **Firefly Importer** | Every import is an operator at the importer UI uploading a config JSON | No scheduled sync exists; `SIMPLEFIN_TOKEN` is a one-shot claim URL | No — redone per import |
| **Cleanuparr** | Configure the arr connections and the malware blocker in the web UI | v2 keeps all of it in `/config` SQLite; `cleanuparr.json` covers only `PORT`/`BASE_PATH`. The account and its OIDC are seeded by `cleanuparr-init` | Yes — `/mnt/fast/cleanuparr/config` |
| **qBittorrent** | Rotating the WebUI password needs `qBittorrent.conf` deleted and the stack redeployed | The conf is seed-once: `qbit-init` writes it only when absent, and qbit rewrites it whole on shutdown | Yes — `/mnt/fast/qbittorrent/config` |
| **Proton / hydroxide** | One interactive `docker exec -it hydroxide … auth <account>` | Env credentials are refused by design so the Proton password never reaches sops; the bridge password prints **once** | Yes — `auth.json` on `/mnt/fast/proton`, but the value must be pasted into `secrets.sops.json` |
| **Syncthing** | Add each peer by device ID, from **both** sides | Deliberate: no device is pre-seeded, so nothing can pair itself | Yes — Syncthing config |
| **SilverBullet** | Create the private Forgejo mirror repo and a `write:repository` PAT, embed both in `GIT_SYNC_REMOTE` | The stack creates neither, by design | Yes — the `secrets.sops.json` value |
| **Wealthfolio** | OIDC is staged but shipped OFF; enabling it is an operator flip | Discovery runs once at startup and its failure aborts boot, so every restart would depend on the VPS | One-shot (compose edit) |
| **Dawarich** | Ensure your Authentik email == `DAWARICH_ADMIN_EMAIL` **before** the first SSO login; Dawarich then asks once for that account's password to link it | Auto-register matches by email; a mismatch mints a second account to merge. Dawarich 1.14 links an SSO identity to an existing account only after a password confirmation | Ordering constraint (one-shot) |
| **Paperless-ngx** | Grant admin/staff in `/admin` if the SSO user needs it | The superuser-group env var first exists in 3.1.0; the compose pins 2.20, where it is silently ignored | Yes — Paperless DB |
| **Frigate** | Per camera: set the admin password and enable HTTP in the Reolink app; reserve its IP on OPNsense | Camera settings live on the device, and the HTTP API that could flip them is itself one of the services that ships off | Yes — on the camera (a factory reset undoes it) |
| **Samba** | *(not a chore — a why)* users authenticate with a local username/password | Built `--without-ldap --without-ads`, so OIDC/AD is not achievable. Credentials are seeded declaratively | n/a |

---

## Per-service detail

### Forgejo → Komodo — the bot, its read token, and the push webhook

- **(a) Service:** Komodo's deploy path (`komodo/`, `nixos/modules/deploy-plane.nix`).
- **(b) The steps,** once per fresh Forgejo:
  1. Forgejo → Site Administration → Create user `komodo` (no admin). On
     `idan/BasicBastardSelfhosted` → Settings → Collaborators, add `komodo`
     with **Read**.
  2. As `komodo` → Settings → Applications → token with scope
     `read:repository` only. `sopsedit komodo/secrets.sops.json`, set
     `KOMODO_GIT_TOKEN`, commit, `nrs-vm` — the switch restarts Core with the
     token and `komodo-sync-bootstrap` creates the `fleet` sync and the
     `apply` procedure from `komodo/fleet.toml`, then registers every stack.
  3. Repo → Settings → Webhooks → Add → Forgejo: URL
     `http://komodo:9120/listener/github/procedure/apply/main`, content type
     `application/json`, secret = `KOMODO_WEBHOOK_SECRET` from
     `komodo/secrets.sops.json`, trigger on push events, branch filter `main`.
     "Test Delivery" deploys the current head.
- **(c) Why not declarative:** the bot, its token and the webhook are rows in
  Forgejo's database, a token can only be minted by a running Forgejo, and
  Forgejo reads no webhook config from env or files.
- **(d) Survives recreate:** yes — Forgejo's DB is on `/mnt/fast/forgejo`, the
  token is a sops value. A Komodo database rebuild needs only the switch (the
  bootstrap re-registers `fleet`; the webhook URL names the procedure, not an id).

### Komodo — an OIDC sign-up lands disabled

- **(b) The step:** after `nrs-vps` (the `komodo-sso` blueprint) and `nrs-vm`,
  click "Login with OIDC" once — that creates `idan`, disabled. Log in locally as
  `admin` (`KOMODO_INIT_ADMIN_PASSWORD`), Settings → Users → `idan`: enable, then
  make Admin. Over the API: `/read/FindUser {"user":"idan"}`, then
  `/write/UpdateUserBasePermissions {"user_id":…,"enabled":true}` and
  `/write/UpdateUserAdmin {"user_id":…,"admin":true}`.
- **(c) Why not declarative:** `KOMODO_ENABLE_NEW_USERS=false` on purpose — the
  UI drives Periphery, which mounts the docker socket, so no account goes live
  without the admin saying so. Authentik already refuses everyone outside
  `Admin`; this is the second lock.
- **(d) Survives recreate:** yes — Komodo DB. The local `admin` stays the
  break-glass login and what `komodo-sync-bootstrap` uses.

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

- **(b) The step:** set `USER_EMAIL` in `stacks/beszel/secrets.sops.json` before the
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

**(2) SSO signs into that seeded user — so its email must be yours.**
Beszel's OAuth2 provider (`clientId`, `clientSecret`, endpoints) lives in the
`users` collection's `oauth2` options inside `data.db`, with no environment
variable for any part of it; `beszel-role` writes it over PocketBase's API from
the superuser session it already opens (`beszel-sso`, Admin group only).
`USER_CREATION` stays off on purpose — an account it minted would get role
`user` and an empty dashboard — so the Authentik login links to the seeded user
**by email**: `USER_EMAIL` must be your Authentik email. The seeded password
stays the break-glass login. The **agent** never traverses Caddy (it dials
`http://127.0.0.1:10452` on the host network), so forward auth is purely a
browser concern.

### Jellyfin — its own logins, seeded

The setup wizard, the first admin and the libraries are all driven from the repo:
`jellyfin-config-init` seeds `config/encoding.xml` before the first start, and
`jellyfin-init` calls `/Startup/*` and `/Library/VirtualFolders`, both of which
are anonymous while the wizard is open. Accounts are declarative too:

- **(b) What runs:** `jellyfin-init` creates the other six users with the
  password Authentik sets for each (from `/run/stack-env/media.jellyfin-users.env`,
  rendered from `stacks/media/env.jellyfin-users.nix` and read by that one
  service) and re-asserts it on every run, so Jellyfin and Authentik agree.
  `jellyfin-config-init` removes any SSO-Auth plugin left by an earlier deploy.
- **(c) Why no OIDC:** Jellyfin's TV and mobile clients cannot follow an OIDC
  redirect, so an SSO plugin would only help the web UI. Seerr signs in with
  these Jellyfin accounts. The heavier option, if ever wanted: Authentik's LDAP
  outpost with `jellyfin-plugin-ldapauth`.
- **(d) Survives recreate:** yes — the accounts live in `/mnt/fast/jellyfin/config`.
- A friend's password change (`sopsedit secrets/shared.sops.json`) reaches
  Jellyfin like every other consumer: `nrs-vm`, then the push — the shared file
  is one of media's tracked config files, so `apply` redeploys media and
  `jellyfin-init` re-asserts the new value.

⚠ **Do not run `sopsgen rotate user/idan` after Jellyfin's first deploy.**
`JELLYFIN_ADMIN_PASSWORD` is a twin of idan's password, and Jellyfin has no
headless password reset — so a rotation changes what `jellyfin-init` logs in
*with*, not what Jellyfin *stores*, and the next deploy fails loudly. Reset the
password in the Jellyfin UI first, or wipe `/mnt/fast/jellyfin/config`.

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

### Actual — the first OIDC login is the owner

- **(b) The step:** after the first deploy that enables OpenID (`docker logs
  actual_init` says so), log in through Authentik as **idan, first**. That login
  also asks once for the server password (`ACTUAL_INIT_PASSWORD`). Add other users
  in the app by their Authentik username.
- **(c) Why not declarative:** `actual-init` enables OpenID itself (`POST
  /openid/enable`, re-applied when the client changes), but the first OIDC login
  becomes the server **owner permanently** and upstream has no way to pre-assign
  it. The server is never handed `ACTUAL_OPENID_*` env: the pinned server would
  then switch itself to OpenID-only at boot, before any password exists. Never
  set `ACTUAL_OPENID_ENFORCE` — it kills the password fallback.
- **(d) Survives recreate:** yes — the OpenID config and ownership live in
  Actual's DB.

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
- 🚨 **Not safe to flip yet:** `tracking-init.sh` POSTs `/api/v1/users/register`
  on every run and tolerates only "already registered", so with registration
  closed it exits FATAL on every redeploy. Guard it first (skip the register
  call when `/api/v1/status` reports registration closed, keep the login
  proof), then flip.

### Firefly III — mint a Personal Access Token by hand

- **(b) The step:** in the Firefly UI (*Profile → OAuth*), mint a Personal Access
  Token and paste it into `stacks/firefly/secrets.sops.json` as
  `FIREFLY_III_ACCESS_TOKEN` for the data importer. Never set
  `FIREFLY_III_CLIENT_ID` — the OAuth client is likewise minted by hand.
- **(c) Why not declarative:** the only `createToken` call in the image sits
  behind a browser session (`OAuthController`), and there is no CLI route to it —
  `laravel/tinker` is not a dependency of Firefly III (it appears in
  `composer.lock` only as a `suggest` string, and `psy/psysh` is absent), so the
  usual `artisan tinker --execute` trick does not exist here. The importer's UI
  loads with the token unset but cannot talk to Firefly until it is set.
- **(d) Survives recreate:** yes, now. Passport signs every token with an RSA
  pair that it generates under the unpersisted `storage/` path, so a recreate used
  to mint a new pair and silently invalidate the token — the importer would start
  401ing with nothing said at deploy time. `PASSPORT_PRIVATE_KEY` /
  `PASSPORT_PUBLIC_KEY` now come from sops (`freeze: true`, because rotating them
  invalidates every issued token), so the token outlives a recreate and only a DB
  rebuild forces a re-mint.

### Firefly Importer — every import is a human at the UI

- **(b) The step:** open the importer, upload the import-configuration JSON, run
  the import. Repeat per import.
- **(c) Why not declarative:** the importer ships **no scheduled sync** — there is
  no cron, no daemon mode, nothing to configure. `SIMPLEFIN_TOKEN` compounds it:
  it is a one-shot claim URL that the SimpleFIN Bridge invalidates on first use,
  and the durable credential it exchanges for lands in a plaintext JSON on the
  operator's machine.
- **(d) Redone every time:** the import configuration is not stored server-side.

### Cleanuparr — v2 is configured through its web UI

- **(b) The step:** in the Cleanuparr UI, add the Radarr/Sonarr/qBittorrent
  connections and configure the malware blocker against the local blocklist under
  `/config`. The login is already done: `cleanuparr-init` claims the one account
  (`idan`, idan's password) and writes its Authentik OIDC settings
  (`cleanuparr-sso`, Admin group only), so the first-run page is never open.
- **(c) Why not declarative:** v2 moved configuration out of environment variables
  into a SQLite database under `/config`. The only env knobs left are `PORT` and
  `BASE_PATH`; every connection, schedule and rule is UI-only, with no import
  endpoint and no config file to seed.
- ⚠ Like Jellyfin's admin: change idan's password in Cleanuparr (Settings →
  Account) **before** `sopsgen rotate user/idan`, or `cleanuparr-init` fails at
  login on the next deploy.
- **(d) Survives recreate:** yes — `/mnt/fast/cleanuparr/config`.

### qBittorrent — the WebUI password is seed-once

- **(b) The step:** after `sopsgen rotate user/idan`, on the services VM:
  ```bash
  docker compose -p media stop qbittorrent
  rm /mnt/fast/qbittorrent/config/qBittorrent/qBittorrent.conf
  # redeploy media in Komodo — qbit-init re-seeds the conf from the new env
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

### Proton / hydroxide — the only interactive login in the fleet

- **(b) The step, once per re-keyed volume:**
  ```bash
  docker exec -it hydroxide /app/hydroxide auth idan@idanreed.com
  #   ... prints "Bridge password: <base64>" — shown ONCE, save it NOW
  sopsedit stacks/proton/secrets.sops.json   # PROTON_BRIDGE_PASSWORD, PROTON_ACCOUNT
  docker restart proton_export
  docker exec proton_export /sync       # first export on demand
  ```
- **(c) Why not declarative:** this is deliberate, not an upstream gap. hydroxide
  refuses environment credentials so the Proton account password never reaches
  sops; the container consumes **no environment at all**. The bridge password it
  prints is the key that decrypts `auth.json`, is stored nowhere else, and is
  displayed exactly once — so the volume alone is useless and `secrets.sops.json` alone is
  useless. It is the only step in the fleet that requires a TTY.
- **(d) Survives recreate:** yes — `auth.json` under `/mnt/fast/proton`, but the
  bridge password must be captured into `secrets.sops.json` at the moment it is printed.

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
  `stacks/silverbullet/secrets.sops.json`.
- **(c) Why not declarative:** the stack deliberately creates neither the repo nor
  the token — a write-scoped credential that a container could mint for itself
  would be a credential a compromised container could mint for itself.
- **(d) Survives recreate:** yes — it is a sops value.

### Wealthfolio — OIDC staged, shipped OFF

- **(b) The step:** flip the OIDC env on in the compose file, if you accept the
  cost below.
- **(c) Why not declarative:** Wealthfolio runs OIDC discovery once at startup
  and a failure aborts the boot, so turning it on makes every restart hostage to
  VPS reachability. The client secret exists; only the flip is manual, and it is a
  judgement call rather than a chore. (Excalidraw's discovery is lazy, so its OIDC
  is on.)
- **(d) One-shot:** a compose edit.

### Dawarich — email must match the seeded admin

- **(b) The step:** before your first SSO login, ensure your **Authentik email
  equals `DAWARICH_ADMIN_EMAIL`**. Dawarich then asks once for that account's
  password to link the SSO identity.
- **(c) Why not declarative:** auto-register matches by email. A mismatch is not
  an error — it silently mints a *second* account you then have to merge. The
  seeding is declarative; the email parity is an operator ordering constraint.
- **(d) One-shot:** effectively an ordering act at first login.

Audiobookshelf has the same trap and no chore: `books-init` gives root
`ABS_ADMIN_EMAIL` (`stacks/books/compose.yaml`) before it switches OIDC on, so
the first SSO login links root. If root ever lacks the email when someone signs
in, Audiobookshelf registers a second, passwordless user with root's username,
and `POST /login` by that username can then resolve to it — `books_init` fails
with `login HTTP 401`. Fix: stop `audiobookshelf`, back up
`/mnt/fast/audiobookshelf/config/absdatabase.sqlite`, delete the `type = 'user'`
duplicate with `PRAGMA foreign_keys = ON` (its rows cascade), start it, and let
`books-init` set the email. Break-glass local login: `…/login/?autoLaunch=0`.

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
`samba-init.sh` from the stack env on every deploy, and the passwords themselves
come from `sopsgen rotate user/<name>`. It is recorded here so the `Local` auth
cell on the Samba row has an explanation.

- **(c) Why not SSO:** the nixpkgs Samba is built `--without-ldap --without-ads`,
  so OIDC/AD integration is **not achievable**. Exposure is tailnet-only.
- **(d) Survives recreate:** yes — re-seeded from the stack env on every deploy.

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

### Frigate — camera-side setup for each Reolink

- **(b) The step:** in the Reolink app, finish the first-run setup (the `admin`
  password, the same letters-and-digits value as `FRIGATE_REOLINK_PASSWORD`), then
  Settings → Network → Advanced → Server Settings: enable **HTTP**, RTSP and
  RTMP. On OPNsense, add a DHCP static mapping for the camera's MAC at the
  address `frigate.yaml` names.
- **(c) Why not declarative:** the settings live in the camera's firmware.
  Reolink's HTTP API could set the ports, but current firmware ships with HTTP
  off and the password unset, so the first touch has to be the app (port 9000).
- **(d) Survives recreate:** yes — stored on the camera; a factory reset undoes
  it.

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
