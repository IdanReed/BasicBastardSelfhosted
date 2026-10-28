# Wall of shame — the manual steps

Every service should come up from the repo — compose, `secrets.sops.json`,
init containers, Authentik blueprints — with nobody clicking through a browser
or `docker exec`-ing into a container. Most do. This is the list of steps
that cannot, and the reason the app gives for each.

An init container that seeds an account over the app's own first-run API is
the fix, not an entry: if you find a declarative path for something below,
delete the entry and record the mechanism in the stack's `compose.yaml`
header. Host and infrastructure steps (the Cloudflare token, Forgejo's admin,
bot and webhook, CI tokens, the Storage Box) are in
[bring-up.md](bring-up.md). `class: pull` entries in
`secrets-gen/manifest.yaml` are the machine-checked half of this list: every
secret obtained by hand.

"Survives" says whether the result lives in persistent state (redone only when
the volume is lost) or must be redone on every recreate.

| Service | The step | Why it cannot be declarative | Survives |
|---|---|---|---|
| Komodo | after your first "Login with OIDC", log in as the local `admin` and enable `idan` as Admin | OIDC sign-ups land disabled on purpose (`KOMODO_ENABLE_NEW_USERS=false`): the UI drives the docker socket | Komodo DB |
| Actual | be the **first** OIDC login (it asks once for the server password) | `actual-init` enables OpenID, but the first OIDC login becomes the permanent owner and upstream cannot pre-assign it | Actual DB |
| Outline | log in once, as `idan`, right after the first deploy | the first login creates and owns the team; no env, CLI or seeder exists | Outline DB |
| Vaultwarden | set a master password in the web vault after the first SSO login | vaults are client-side E2EE; no server-side seed can create a vault key | `db.sqlite3` |
| Paperless-ngx | grant staff/admin to the SSO user in `/admin` | the superuser-group variable first exists in 3.1; the stack pins 2.20 | Paperless DB |
| Dawarich | make your Authentik email equal `DAWARICH_ADMIN_EMAIL` **before** the first SSO login; confirm the password once to link | auto-register matches by email; a mismatch mints a second account | ordering, once |
| Profilarr | bind the Dictionarry profiles to the Radarr/Sonarr instances | `/api/v1/arr` is GET-only; the binding is a session-cookie form action | `/mnt/fast/profilarr` |
| Cleanuparr | configure the arr and qBittorrent connections and the malware blocker | v2 keeps all of it in its SQLite; env covers only `PORT`/`BASE_PATH`. The account and its OIDC are seeded by `cleanuparr-init` | `/mnt/fast/cleanuparr` |
| Grafana | install the VictoriaLogs datasource plugin on the host | the image that bakes it in (`stacks/logging/Dockerfile`) is not yet published, so the compose pins stock Grafana | `/mnt/fast/grafana/plugins` |
| Firefly III | mint a Personal Access Token for the importer (Profile → OAuth) into `FIREFLY_III_ACCESS_TOKEN` | the only `createToken` path is a browser session; `artisan tinker` is not in the image | Firefly DB (Passport's keys come from sops) |
| Firefly importer | every import: upload the import config JSON in its UI | no scheduled sync exists; `SIMPLEFIN_TOKEN` is a one-shot claim URL | no |
| Homebox | close `HBOX_OPTIONS_ALLOW_REGISTRATION` after the first deploy — **not yet safe**, see below | the open window *is* the headless bootstrap | compose value |
| qBittorrent | a WebUI password change needs `qBittorrent.conf` deleted and media redeployed | the conf is seed-once: qbit rewrites it whole on shutdown | `/mnt/fast/qbittorrent` |
| Proton / hydroxide | one interactive `hydroxide auth <account>` per re-keyed volume | env credentials are refused by design; the bridge password prints **once** | `auth.json`, but the value goes into sops |
| Syncthing | add each peer by device ID, from both sides | deliberate: pairing is the trust establishment | Syncthing config |
| SilverBullet | create the private mirror repo and a `write:repository` PAT for `GIT_SYNC_REMOTE` | deliberate: a container that mints its own write credential could be made to | sops value |
| Wealthfolio | OIDC is staged but off; turning it on is a compose edit | discovery runs once at boot and a failure aborts it, so every restart would depend on the VPS | compose value |
| Frigate | per camera: the admin password and HTTP on in the Reolink app; a DHCP reservation on OPNsense | the settings live in the camera's firmware, which ships with HTTP off | on the camera |

## Detail

### Komodo

Click "Login with OIDC" once (after `nrs-vps` has applied the `komodo-sso`
blueprint) — that creates `idan`, disabled. Log in as `admin`
(`KOMODO_INIT_ADMIN_PASSWORD`), Settings → Users → `idan`: enable, then Admin.
Over the API: `/read/FindUser {"user":"idan"}`, then
`/write/UpdateUserBasePermissions {"user_id":…,"enabled":true}` and
`/write/UpdateUserAdmin {"user_id":…,"admin":true}`. The local `admin` stays
the break-glass login and what `komodo-sync-bootstrap` uses.

### The "first login owns it" apps

Actual and Outline make whoever logs in first the permanent owner. On a
tailnet every enrolled device could be first, so log in as `idan` right after
the first deploy. Never set `ACTUAL_OPENID_ENFORCE` — it kills the password
fallback. Outline has no local accounts at all: its OIDC secret is the login.

Two apps look like this family and are not: Homebox's owner is pre-created by
`tracking-init`, and BookStack's admin comes from membership of the Authentik
group `Admin`, re-asserted on every login.

### Grafana plugin

```bash
curl -fL -o /tmp/vl-ds.zip \
  https://grafana.com/api/plugins/victoriametrics-logs-datasource/versions/0.31.0/download
mkdir -p /mnt/fast/grafana/plugins
unzip /tmp/vl-ds.zip -d /mnt/fast/grafana/plugins
chmod +x /mnt/fast/grafana/plugins/victoriametrics-logs-datasource/victoriametrics_logs_backend_plugin_*
docker restart grafana
```

The `chmod +x` is load-bearing: without it Grafana logs "Could not start
plugin backend" and reports healthy. Until the plugin is in, the stopgap is
vmui at `http://127.0.0.1:10456/select/vmui/`. Publishing
`ghcr.io/idanreed/grafana-vlogs` (`.github/workflows/build-grafana-vlogs.yml`)
and pinning it removes this entry ([decisions.md](decisions.md), D-39).

### Homebox

`tracking-init` POSTs `/api/v1/users/register` on every run and tolerates only
"already registered", so with registration closed it exits FATAL on every
redeploy. Guard the register call on `/api/v1/status` first, then close it.

### qBittorrent

```bash
docker compose -p media stop qbittorrent
rm /mnt/fast/qbittorrent/config/qBittorrent/qBittorrent.conf
# redeploy media in Komodo — qbit-init re-seeds the conf from the new env
```

`qbit-init` compares the stored hash with the env and prints four WARN lines
when they diverge.

### Proton / hydroxide

```bash
docker exec -it hydroxide /app/hydroxide auth idan@idanreed.com
#   prints "Bridge password: <base64>" ONCE
sopsedit stacks/proton/secrets.sops.json   # PROTON_BRIDGE_PASSWORD, PROTON_ACCOUNT
# commit, nrs-vm, push — a docker restart does not re-read the env
docker exec proton_export /sync            # first export on demand
```

The bridge password decrypts `auth.json` and is stored nowhere else, so the
volume alone and the sops value alone are both useless. The only TTY step in
the fleet.

### Beszel

The app login is PocketBase's `users` collection, seeded from `USER_EMAIL` and
idan's password, and `beszel-role` promotes it to admin and writes the
`beszel-sso` OAuth2 provider. The pair is read **only against a virgin
`data.db`**: set `USER_EMAIL` (your Authentik email — SSO links by it) and
`FILESYSTEM` before the first boot. If only one of the two is set, Beszel
mints a throwaway superuser and the browser first-run form becomes the only
way in.

### Jellyfin

Not a chore — a reason: Jellyfin has no OIDC here because its TV and mobile
clients cannot follow an OIDC redirect. Its users come from Authentik through
the LDAP outpost; the local `idan` admin seeded by `jellyfin-init` is the
break-glass login. Change that admin's password in the Jellyfin UI **before**
`sopsgen rotate user/idan`, or the next deploy fails at `jellyfin-init`'s
login.

### Audiobookshelf

Not a chore: `books-init` gives the root user `ABS_ADMIN_EMAIL` before it
turns OIDC on, so the first SSO login links root. If root ever lacks the email
when someone signs in, Audiobookshelf registers a second, passwordless user
with root's username and `books_init` fails with `login HTTP 401`. Fix: stop
`audiobookshelf`, back up `/mnt/fast/audiobookshelf/config/absdatabase.sqlite`,
delete the `type = 'user'` duplicate with `PRAGMA foreign_keys = ON`, start
it, and let `books-init` set the email. Local login: `…/login/?autoLaunch=0`.

## Adding an entry

A row in the table, plus a detail block if the step needs more than a line:

```markdown
### <Service>

<the exact step — UI path, command or API call>. <Why the app makes it
manual: the specific mechanism, not "no API">. <Where the result persists, or
"redone on every recreate">.
```

Confirm first that no init container could take the step over the app's own
API.
