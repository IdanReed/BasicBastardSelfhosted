# Accounts

Who has an account, how someone new gets one, and how `idan` is the admin of
each service.

| Account | Where it comes from | Credential |
|---|---|---|
| `idan` | declared in `headscale-vps/authentik/blueprints/custom/headscale-oidc.yaml`, groups `headscale-users` and `Admin` | `IDAN_INITIAL_PASSWORD` (`secrets/shared.sops.json`), re-asserted on every blueprint apply, plus TOTP. Change it with `sopsgen rotate user/idan` ([bring-up.md](bring-up.md) §15) |
| everyone else | an invitation (below) — internal users in `headscale-users` | their own password and TOTP |
| `akadmin` | Authentik's bootstrap | `AUTHENTIK_BOOTSTRAP_PASSWORD` — break-glass only |

`Admin` is the fleet's one privilege handle: an Authentik superuser group, and
the group apps map to their own admin role. It holds `idan` alone; never add
an invitee to it.

## Inviting someone

1. From the desktop:

   ```bash
   headscale-vps/invite.sh <username> <email> ["Display Name"]
   ```

   It mints the invitation on the VPS over ssh and prints the link: single
   use, expires in 7 days, username and email fixed. Rerunning it for the same
   username reprints the unused link. It refuses a username or email that
   already has an account. (The admin UI, Directory → Invitations, works too:
   flow `invite-enrollment`, single use, fixed data
   `{"username": …, "email": …}`.)
2. Send them the link. Opening it spends it; if they abandon the form, mint a
   new one. The flow (`invite-enrollment.yaml`) shows the username and email
   read-only, asks for a name and a password (12+ characters), makes them set
   up TOTP, and ends logged in.
3. Their devices join with
   `tailscale up --login-server=https://headscale.idanreed.com` and the same
   Authentik login.
4. The per-app steps in the next table, if they need those apps.

The email matters: apps link an Authentik login to an existing local account
by email, so the invitation fixes it, and users cannot change their email or
username afterwards (the tenant defaults, pinned by the authentik suite).

### What an invited user gets

| Service | On first login |
|---|---|
| OIDC apps (Immich, Paperless, Kavita, Audiobookshelf, Outline, BookStack, Homebox, Karakeep, Dawarich, Ghostfolio, Tandoor, Mealie, Excalidraw, Forgejo, DocSpace) | "Sign in with Authentik" creates a normal, non-admin account |
| Everyday forward-auth apps (BentoPDF, Mazanoke, IT-Tools, Glance, Shelfmark, Frigate as `viewer`, Firefly III, Owl, Wger) | reachable after the Authentik login |
| Jellyfin, Seerr | their Authentik username and password through the LDAP outpost (no TOTP — LDAP cannot prompt); Seerr follows Jellyfin |
| Vaultwarden | SSO login, then they set a **master password** in the web vault — it is the vault key, and Authentik can never reset it |
| Windmill, Wger | nothing until added: one roster line in `stacks/windmill/windmill-init.sh` (`(email, None, False, SSO_PROVIDER)`) or `stacks/wger/wger-init.py` (`(username, email, False)`), then push |
| Actual | nothing until an admin adds them in the client's user directory (the `userName` is their Authentik username) |
| Admin-only apps — the admin tools (Komodo, Grafana, Beszel, Gatus, Backrest, Windmill, Radarr, Sonarr, Prowlarr, Bazarr, Profilarr, Cleanuparr, Bitmagnet, the Firefly importer, Vaultwarden `/admin`) and idan's single-user apps (Syncthing, SilverBullet, Grist, Penpot) | refused — those applications are bound to `Admin` |

⚠ **Before the first invitation:**

- **Claim the first-login apps as idan** (the table below: Outline, Firefly
  III, Ghostfolio, and the Paperless and Komodo steps) — an invitee's first
  login there would otherwise own it.
- **What an invitee's devices reach:** `headscale-vps/policy.hujson` gives
  every non-owner account (`autogroup:member`) the services VM's :443 and
  nothing else. Caddy fronts every vhost, so the per-app control is
  Authentik's: an application with no binding admits every Authentik user. A
  new admin tool or single-user app gets an `Admin` policybinding in
  `forward-auth.yaml` (or its `*-oidc.yaml`) in the same change that adds it.

To remove someone: Authentik → Directory → Users → deactivate (or delete),
`sudo headscale nodes expire -i <id>` for their devices, then their accounts in
the apps that keep one.

## How idan is admin in each service

Declarative = it comes from the repo on a fresh deploy. "Group" rows re-derive
admin from Authentik's `Admin` group on every login (the `profile` scope's
`groups` claim, or the outpost's groups header), so they also demote anyone
outside it.

| Service | How idan is admin | Declarative | Operator step |
|---|---|---|---|
| Authentik | `Admin` is a superuser group (`headscale-oidc.yaml`) | yes | — |
| Headscale | no web UI: `sudo headscale …` on the VPS; `idan@` owns the ACL | yes | — |
| BookStack | group sync: `Admin` → its Admin role (`OIDC_USER_TO_GROUPS`) | group | — |
| Grafana | `role_attribute_path`: `Admin` → org Admin, strict | group | — |
| Mealie | `OIDC_ADMIN_GROUP=Admin` | group | — |
| Forgejo | auth source `--admin-group Admin` (`forgejo-init.sh`) | group | — |
| Kavita | `roles` claim with `Admin` for `Admin` members (`kavita-oidc.yaml`), synced by `syncUserSettings` (`books-init`); the local `idan` is the default admin | group | — |
| Shelfmark | `PROXY_AUTH_ADMIN_GROUP_NAME=Admin` | group | — |
| Frigate | proxy `role_map`: `Admin` → admin, everyone else `viewer` | group | — |
| Jellyfin, Seerr | local `idan` admin from `jellyfin-init`; LDAP `Admin` members are Jellyfin admins; Seerr follows Jellyfin | yes | — |
| Profilarr | single-user; `profilarr-sso` bound to `Admin` | yes | — |
| Cleanuparr | `cleanuparr-init` claims the one account as `idan`; SSO bound to `Admin` | yes | — |
| Beszel | `beszel-role` promotes the `USER_EMAIL` account; SSO bound to `Admin` | yes, on a virgin `data.db` | `USER_EMAIL` before the first boot ([for-shame.md](for-shame.md)) |
| Immich | `immich-init` signs up the admin with idan's email; OIDC links by email | yes | — |
| Audiobookshelf | `books-init`: root `idan` with idan's email; OIDC matches by email | yes | — |
| Homebox | `tracking-init` registers idan, the group owner; OIDC links by email | yes | — |
| Karakeep | `tracking-init` creates idan first, so admin; OIDC links by email | yes | — |
| Dawarich | `dawarich-init` creates or promotes `DAWARICH_ADMIN_EMAIL` | yes | confirm the password once at the first SSO login ([for-shame.md](for-shame.md)) |
| Tandoor | `tandoor-init` superuser with a verified email; email authentication links the SSO login | yes | — |
| Wger | `wger-init`: superuser `idan` (SSO only) beside the `admin` break-glass | yes | — |
| Windmill | `windmill-init`: superadmin `idan`, password login | yes | — |
| Actual | `actual-init` seats `idan` as ADMIN before OpenID exists | yes | — |
| DocSpace | `docspace-init` completes the wizard as idan (owner); SAML links by email | yes | — |
| Excalidraw | `SUPERADMIN_EMAILS` includes idan's | yes | — |
| Grist | `GRIST_ADMIN_EMAIL` is idan's: install admin and owner of the team site; SSO bound to `Admin` | yes | — |
| Penpot | his SSO login creates the only profile (`PENPOT_OIDC_ROLES: Admin`); SSO bound to `Admin` | mostly | confirm the name once at the first login ([for-shame.md](for-shame.md)) |
| Home Assistant | `automation-init` onboards `idan` as owner | yes | — |
| rmfakecloud | `notes-sync-init` creates the first user, an admin, with idan's email | yes | — |
| Vaultwarden | `/admin` behind `ADMIN_TOKEN` (sops) and forward auth; users have no admin role | yes | — |
| Wealthfolio | one password, `WF_AUTH_PASSWORD_HASH` | yes | — |
| Backrest | seeded user `admin` with idan's password, behind forward auth | yes | — |
| qBittorrent, Syncthing, SilverBullet | one seeded login each, idan's | yes | — |
| Paperless-ngx | — | no | grant superuser to the SSO `idan` in `/admin` ([for-shame.md](for-shame.md)) |
| Komodo | — | no | enable `idan` as Admin after the first OIDC login ([for-shame.md](for-shame.md)) |
| Outline | the first login creates and owns the workspace | no | log in as idan first |
| Firefly III | the first email the remote-user guard sees becomes the owner | no | open it as idan first |
| Ghostfolio | the first account becomes ADMIN | no | log in as idan first |
| Radarr, Sonarr, Prowlarr, Bazarr, Firefly importer, Gatus, Glance, BentoPDF, Mazanoke, IT-Tools, Owl, Ntfy | no accounts — forward auth (or the tailnet) is the gate | n/a | — |

Outline, Firefly III and Ghostfolio give the server to whoever signs in
first: after a first deploy idan logs in to each — and does the Paperless and
Komodo steps — **before** any invitation goes out.
