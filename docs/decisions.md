# Decisions deferred from the 2026-09-07 code review

Functional changes the review branch `worktree-code-review` found but deliberately did **not** make,
because each needs an operator decision. Use it as a queue: decide → implement → delete the entry.
The full per-lane review-session reports (nixos-vm, vps, desktop, sops, stacks-a, stacks-b, tests,
arch-security, declarative, docs-audit) are **not** in the repo; the arch-security findings (AS-nn)
are summarised below, so this file stands alone. 61 decisions, 9 accepted risks.

---

## Operator to-dos (no decision needed, just sudo)

Run from the repo root on the desktop. `sopsgen`/`sopsedit` prompt for sudo (the age key lives only
at `/var/lib/sops-nix/sops_age_key.txt`).

**Land the new `.example` key grouping in the real encrypted files:**

```bash
sopsgen sort --dry-run    # prints the plan, writes nothing
sopsgen sort              # all 35 managed files, in place
git diff --stat           # only ciphertext blobs should move
sopsgen apply             # fill any key added to a .example but missing from a real file
./tests/run.sh && SERVER_NOTES=../ServerNotes ./tests/run.sh deploy-check
```

**Fill the ~15 values whose ciphertext length still matches their old `changeme_` placeholder**
(confirm each first with `sopsgen view <stack>` — the sops lane cleared `SAMBA_RYLAN_PASSWORD` and
`RYLAN_INITIAL_PASSWORD` as real values that happen to be placeholder-length, so check before editing):

```bash
sopsedit stacks/media/.sops.env          # WIREGUARD_PRIVATE_KEY, WIREGUARD_ADDRESSES, SERVER_COUNTRIES, VPN_SERVICE_PROVIDER, QBIT_WEBUI_USER
sopsedit stacks/proton/.sops.env         # PROTON_ACCOUNT, PROTON_BRIDGE_PASSWORD
sopsedit stacks/ntfy/.sops.env           # NTFY_SMTP_SENDER_PASS
sopsedit stacks/beszel/.sops.env         # FILESYSTEM (findmnt -no SOURCE / on the VM), TOKEN
sopsedit stacks/actual/.sops.env         # ACTUAL_OPENID_CLIENT_ID
sopsedit stacks/firefly/.sops.env        # SIMPLEFIN_TOKEN (and confirm APP_KEY is real)
sopsedit nixos/forgejo-runner.sops.env   # TOKEN          — then nixos-rebuild the services VM
sopsedit nixos/renovate.sops.env         # RENOVATE_TOKEN — then nixos-rebuild the services VM
```

**Fill the keys the branch's LAST commit adds** — that commit is labelled *"needs sopsgen apply"*, and until these
values exist its `stack-env-drift` lint is **red by design**: `firefly` (2 keys) and `media` (6 keys), in both the
example-vs-real and fixture-vs-real comparisons. Every other lint is green, and there is nothing to `git apply`.

```bash
sopsgen apply                     # firefly PASSPORT_PRIVATE_KEY + PASSPORT_PUBLIC_KEY (rsa-4096, freeze:true);
                                  #   media SEERR_API_KEY, API_KEY, BAZARR_API_KEY
sopsgen rotate user/idan          # media JELLYFIN_ADMIN_PASSWORD — a copy_only twin, only `rotate` propagates it
sopsedit stacks/media/.sops.env   # JELLYFIN_ADMIN_USER, SEERR_ADMIN_EMAIL — config class, hand-set
./tests/run.sh                    # goes green the moment the above are written
./deploy media firefly
```

Two hazards, both written into the `.sops.env.example` files as well:
`sopsgen rotate user/idan` **after** the first Jellyfin deploy is a deploy failure by design — Jellyfin has no
headless password reset, so the rotation changes what `jellyfin-init` logs in with, not what Jellyfin stores; reset
it in the Jellyfin UI or wipe `/mnt/fast/jellyfin/config` first. And the Passport keypair is `freeze: true`, so a
later `rotate` needs `--force`: rotating it invalidates every issued Firefly token, which is the whole point of
persisting it.

**Heavy suites the branch could not run** (each boots VMs; budget 5-20 min apiece):

```bash
SERVER_NOTES=../ServerNotes ./tests/run.sh rotation   # exercises the repaired tests/fixtures/vps-rotated.sops.yaml
SERVER_NOTES=../ServerNotes ./tests/run.sh gitops     # komodo push -> sync -> decrypt -> deploy
SERVER_NOTES=../ServerNotes ./tests/run.sh windmill   # changed by stacks-b, never booted
```

Already run green by the apply lanes, so no need to repeat: `vps` (security-apply, including the new traversal
negative), and `media`, `books`, `beszel`, `firefly`, `tracking`, `vaultwarden`, `victorialogs`, `util`, `logging`,
`ntfy` (declarative-apply, stacks-a, stacks-b, tests). `media` passed on both trees — with the last commit's new
keys applied and with them reverted.

**Facts to look up on the live fleet** — each unblocks a decision below:

```bash
ssh idan@10.0.0.3 'ip link show ens18'            # D-42: which MAC the live VM actually has
ssh idan@10.0.0.3 'tailscale ip -4'               # D-03: the services-VM tailnet IP for trusted_proxies
ls -l /dev/disk/by-id/ | grep nvme                # D-45: the by-id path of the desktop's root disk
```

**Offline age-key escrow (AS-16, no command in the repo can do this):** put a paper or
hardware-token copy of `/var/lib/sops-nix/sops_age_key.txt` and a plaintext note of the Hetzner
Storage Box credentials somewhere off-fleet. `secrets-recovery.sops.yaml` does **not** cover this —
it is encrypted to the same key.

---

## Decisions

### Security

#### D-01 Split the age recipient per host
**Area** Secrets/Security · **Raised by** arch-security (AS-1, Critical) · **Severity/effort** Critical / M
**Context:** `.sops.yaml` names one recipient for every rule, and the matching private key is installed at
`/var/lib/sops-nix/sops_age_key.txt` on all three hosts — including the only internet-facing one. Root on
the VPS therefore yields `RESTIC_PASSWORD` + the storage-box SSH key (read *and delete* on offsite backups),
`CLOUDFLARE_API_TOKEN`, Vaultwarden's `ADMIN_TOKEN`, every OIDC secret and every user's initial password.
The VPS itself needs exactly two OS secrets plus its Authentik template.
**Options:**
- Keep one recipient; record the blast radius explicitly in `CLAUDE.md` instead of it reading as convenience.
- Per-host age keys: operator key stays a recipient of everything; `headscale-vps/secrets.sops.yaml` also gets the VPS key, `nixos/secrets.sops.yaml` + `*.sops.env` also get the services-VM key. Costs one `sops updatekeys` pass over ~40 files plus edits to `nixos/build_proxmox.sh` and `headscale-vps/deploy.sh`.
- Per-host keys plus rotating the current key (assumes it is already over-exposed).
**Recommendation:** Split per host, before any guest node exists — highest-leverage change in the review.

#### D-02 ntfy is anonymous read-write, with SMTP submission attached
**Area** Security · **Raised by** arch-security (AS-2, High), stacks-b · **Severity/effort** High / M
**Context:** `stacks/ntfy/server.yml` sets `auth-default-access: "read-write"` over an empty auth db. Any
tailnet peer, any container on the `homelab` network, and any local uid on the services VM can publish and
subscribe. Consequences: outbound mail relay as `alerts@idanreed.com` (ntfy forwards on `X-Email`),
disclosure of a week of `systemctl status --lines=30` bodies posted by `notify-failure@`, and the ability to
flood `alerts` and drown the backup dead-man. The risk is now documented in the file (applied) but not closed.
Forward auth is not available: the VPS publishes *through* Caddy and a 302 would swallow the alert. This is also
one of the two `TODO: decide` entries in `auth-coverage-required`'s `UNAUTHENTICATED_OK` table
(`tests/lib/lints.nix`), so `./tests/run.sh deploy-check` will print it on every run until it is ruled on.
**Options:**
- Leave it — the tailnet is the perimeter. Replace the `TODO: decide` with a plain ACCEPTED reason so the scan goes quiet.
- `deny-all` + tokens across the **eight** publishers the applied header now enumerates (both hosts' `notify-failure@`, `firefly-cron`, silverbullet git-sync, Backrest's shoutrrr hook, gatus, `scan-downloads`, the heavy-nightly workflow) plus a read token for the phone, and a `secrets-gen/manifest.yaml` entry. Note arch-security estimated five call sites; there are eight.
- Halfway: keep read-write but drop the SMTP block, removing the mail-relay leg only.
**Recommendation:** deny-all + tokens; the mail-relay leg is the part that reaches a third party.

#### D-03 `trusted_proxies static 100.64.0.0/10` spans the whole tailnet
**Area** Security · **Raised by** arch-security (AS-4, High; open since security-review-2026-08-30 #3) · **Severity/effort** High / S
**Context:** `headscale-vps/modules/caddy.nix` `globalConfig` trusts the entire tailnet range, so any peer can
forge `X-Forwarded-For`. Two controls built *after* that finding now key on the forged value: the fail2ban
`authentik` filter's `failregex` (`headscale-vps/configuration.nix`) and `login-hardening.yaml`'s reputation
policy `check_ip`. Result: invisible brute force, and the ability to make Authentik ban arbitrary third-party IPs.
**Options:**
- Narrow to the services VM's /32 (`TAILNET_IP` in `stacks/caddy/.sops.env` is `100.64.0.2`) — confirm with `tailscale ip -4` first; a wrong value 404s every forward-auth check.
- Leave and accept, recording that fail2ban and the reputation policy's IP half are advisory on the tailnet.
**Recommendation:** narrow to the /32 after confirming the address.

#### D-04 Backrest is exempt from forward auth with no stated reason
**Area** Security · **Raised by** security-apply (the new `auth-coverage-required` lint), arch-security (AS-5) · **Severity/effort** Medium / S
**Context:** The new `auth-coverage-required` lint in `tests/lib/lints.nix` requires every `handle @x` in
`stacks/caddy/Caddyfile` to be forward-authed, present in an Authentik OIDC blueprint's `redirect_uris`, or
listed in `UNAUTHENTICATED_OK` with a written reason. It is green today with 8 exemptions, of which **two are
seeded `TODO: decide`** and are printed by `./tests/run.sh deploy-check`. This is the backrest one:
`@backrest` has no justification comment in the Caddyfile at all. Backrest does have its own bcrypt login
(`stacks/backrest/config.template.json`), so the exemption is probably intentional — but nothing says so, and
that same login is the one D-26 shows a `sopsgen rotate` never actually reaches. (The ntfy `TODO: decide` is
D-02. `@paperless`, the third route arch-security flagged as uncommented, needs no exemption — it passes on
the OIDC leg via `paperless-oidc.yaml` — but it still has no Caddyfile comment.)
**Options:**
- Confirm the exemption: replace the `TODO: decide` with the real reason (Backrest owns its login) and add the matching one-line comment to the Caddyfile handle.
- `import protected` on `@backrest` and delete the exemption — Backrest's UI is a browser path, so a 302 is harmless; it would then have two auth layers.
- Leave the marker as a standing reminder (it will keep printing on every `deploy-check`).
**Recommendation:** add `import protected` — it is a browser-only UI with no non-interactive client, so the cheap layer is free. Add the `@paperless` comment in the same change.

#### D-05 The headscale ACL is inert — no node advertises tags
**Area** Security · **Raised by** arch-security (AS-6, High) · **Severity/effort** High / M
**Context:** `headscale-vps/policy.hujson` defines `tag:server` and `tag:guest`, but neither `tailscale up`
invocation (`nixos/modules/network.nix`, `headscale-vps/configuration.nix`) passes `--advertise-tags`. Only
rule 1 (`idan@ → *:*`) ever matches; a future node registered untagged inherits `*:*`. The guest-rule caveat
that `:443` is Caddy and therefore fronts every vhost has been added to the file (applied); the tagging has not.
**Options:**
- Leave until a guest node is actually needed.
- Add `--advertise-tags=tag:server` to both `tailscale up` calls. Tags cannot be applied retroactively, so both nodes must re-register (a preauthkey each; the VPS registers against its own control plane).
**Recommendation:** do it at the next planned re-image, not opportunistically. Note that `auth-coverage-required` (applied) now blocks a *new* unauthenticated route, but does not retro-protect the 8 exempt ones a guest would reach through `:443`.

#### D-06 The backup SSH key is still passwordless root on the public VPS
**Area** Security · **Raised by** arch-security (AS-3, High) · **Severity/effort** High / M
**Context:** `nixos/backup-prepare.sh` reaches the VPS with `BACKUP_VPS_SSH_KEY` and runs `sudo docker exec`,
`sudo sqlite3` and `rsync --rsync-path='sudo rsync'`. `security.sudo.wheelNeedsPassword = false` is set on the
VPS, so the key is root-equivalent there, and it is stored as a plain file on the services VM at
`/var/lib/backup/vps_ed25519`. The `restrict` key option (no pty/forwarding/user-rc) **has been applied** in
`headscale-vps/configuration.nix`; the authority itself has not been narrowed. This inverts the trust gradient:
the VM runs a CI runner, a torrent client and internet-facing scrapers.
**Options:**
- Stop at `restrict` (applied) and accept root-via-sudo.
- Add `command="/run/current-system/sw/bin/vps-backup-pull"` to the key plus a `security.sudo.extraRules` entry limiting that wrapper's three sudo calls, and have `backup-prepare.sh` invoke it.
**Recommendation:** schedule the forced command; failure is loud (`rc_vps=1` → `OnFailure` → ntfy).

#### D-07 Zero `no-new-privileges` / `cap_drop` / `read_only` across ~120 containers
**Area** Security · **Raised by** arch-security (AS-12), vps, stacks-a · **Severity/effort** Medium / M
**Context:** Grep across `stacks/`, `komodo/` and `headscale-vps/` returns **0** hits for `security_opt`,
`cap_drop` and `read_only`. The positive discipline is good (one docker socket, `privileged:` never, `cap_add`
once for gluetun) but nothing is given back. Three lanes raised this independently; stacks-a supplied the
blocker: every LinuxServer/s6 image (qbittorrent, radarr, sonarr, prowlarr, bazarr, bookstack) uses a setuid
step-down that `no-new-privileges` breaks, so a fleet-wide flag is a fleet-wide outage.
**Options:**
- Leave as is.
- Pilot `no-new-privileges:true` on the highest-exposure, non-s6 containers only: `shelfmark`, `karakeep_chrome`, `meilisearch`, `profilarr`, `victorialogs`, `excalidraw_room`, `hydroxide`, `clamav_scanner` — one `run.sh stack <name>` per addition.
- Fleet-wide with a lint (rejected by stacks-a).
**Recommendation:** pilot on the two internet-facing scrapers (`shelfmark`, `karakeep_chrome`) at minimum; the rest optional.

#### D-08 A shared `env_file` gives every sidecar the whole stack's secret set
**Area** Security · **Raised by** arch-security (AS-11) · **Severity/effort** Medium / M
**Context:** Most services in a stack receive the whole `.env`. The repo already knows the fix and applied it
once — `shelfmark` in `stacks/books/compose.yaml` names its six values individually as `${VAR:-}` with the
reasoning written out. Unapplied elsewhere: `karakeep_meilisearch` (`stacks/tracking/compose.yaml`) needs only
`MEILI_MASTER_KEY` but receives BookStack's MySQL root password, `NEXTAUTH_SECRET`, `HBOX_AUTH_API_KEY_PEPPER`
and three OIDC secrets; `gluetun` (`cap_add: NET_ADMIN`) receives all four Servarr API keys; `profilarr` pulls
remote definitions and receives the whole media `.env`; `frigate` has `device_cgroup_rules` over the USB tree
and receives Home Assistant's credentials; every `*_db` container receives its app's JWT signing key.
The `meilisearch` case (AS-11) is **applied** — `stacks/tracking/compose.yaml` now names
`MEILI_MASTER_KEY=${MEILI_MASTER_KEY:-}` instead of taking the whole `.env`. The other three are open, and the
branch's last commit adds a **fourth**: `seerr` takes the whole media `.env` so it can read `API_KEY`, where
`- API_KEY=${SEERR_API_KEY:-}` in `environment:` would do — and would remove one managed key (the two names are one
draw today). It was left as `env_file` only because that is the form the passing media suite validated.
**Options:**
- Leave — `env_file` is the house pattern and finding #11's `required: false` semantics are well understood.
- Convert `gluetun` (VPN vars only), `profilarr`, `frigate` and `seerr` to explicit `${VAR:-}` environment entries (lint-safe: `env-file-coverage` checks per stack, `stack-env-drift` checks key parity — neither looks at per-service usage). Re-run `./tests/run.sh media` after the seerr one.
- Additionally add a `stack-env-scope` lint: `env_file:` allowed only for services listed in a per-stack `SHARED_ENV_OK` dict with a reason.
**Recommendation:** convert the four, `seerr` first since it also drops a key, then decide on the lint.

#### D-09 CI executes workflow code on the production services VM
**Area** Security · **Raised by** arch-security (AS-13) · **Severity/effort** Medium / S
**Context:** `nixos/modules/forgejo-runner.nix` runs jobs as a DynamicUser on 10.0.0.3 with `nix`, `curl`,
`openssh`, `nodejs` and unrestricted network. The module's own hardening is good (an assertion forbids any
`:docker:` label; the DynamicUser is an untrusted nix-daemon client). The gap is ambient: a host-mode job shares
loopback with every stack's publish — VictoriaLogs `:10456` (read *and* write), ntfy `:10001`, Home Assistant
`:10250`, qBittorrent `:10057`, Forgejo `:10550`, Komodo Core `:10000` — plus the tailnet via `--accept-routes`.
`.forgejo/workflows/suites.yml` triggers on `pull_request`. The real boundary is "who can open a PR", which is
Authentik-gated with registration disabled — but that is written down nowhere.
**Options:**
- Record the boundary in the module header and accept.
- Move the runner to `nixos-de` (the module header already costs this out: not always on, pushes queue).
- Both, with per-instance labels.
**Recommendation:** record the boundary now; move when the desktop's uptime story improves.

#### D-10 Authentik's `akadmin` and bootstrap API token are permanent, unrotated fleet-root credentials
**Area** Security · **Raised by** arch-security (AS-14), vps (Decision 3) · **Severity/effort** Medium / M
**Context:** `headscale-vps/modules/authentik.nix` renders `AUTHENTIK_BOOTSTRAP_PASSWORD` and
`AUTHENTIK_BOOTSTRAP_TOKEN`; `headscale-vps/authentik/compose.yaml` passes both to the worker with `${VAR:?}`
guards described as "ignored on later starts". The *account* and the *token it created* are not ignored — they
persist in the Authentik DB, and no blueprint under `authentik/blueprints/custom/` deactivates either. The token
is full-API and identical across every rebuild. The test suites supply their own value, so dropping it from
production would not affect them.
**Options:**
- Keep as a deliberate break-glass path and document it in `maintenance-handbook.md`, `core-oidc.md` and `login-tiers.md`.
- Add a blueprint entry deactivating `akadmin` and revoking the token once `idan` exists.
- Keep but rotate on a schedule.
**Recommendation:** document first (cheap and honest), retire `akadmin` when the per-app OIDC UI steps are done.

#### D-11 No patch cadence on the public host
**Area** Security · **Raised by** arch-security (AS-15; open since security-review-2026-08-30) · **Severity/effort** Medium / S
**Context:** `grep -rn autoUpgrade --include="*.nix"` returns nothing. `headscale-vps` runs sshd, Caddy and a
kernel exposed to the internet plus Authentik/Postgres/Redis containers, pinned to `nixos-25.11`. Renovate opens
PRs weekly and never merges by design, so image freshness is gated on the operator.
**Options:**
- `system.autoUpgrade` on the VPS with `allowReboot = false`, flake pinned to the branch — patches land, reboots stay manual.
- A calendar cadence (monthly `nrs-vps`).
- Accept and record the decision in `_todo.md`'s declined list (it was asked for in 2026-08-30 and never answered either way).
**Recommendation:** autoUpgrade on the VPS only; the services VM is tailnet-only and can stay manual.

#### D-12 fail2ban can lock a tailnet device out of SSH
**Area** Security · **Raised by** vps (Decision 2) · **Severity/effort** Medium / S
**Context:** In `headscale-vps/configuration.nix`, `[DEFAULT] ignoreip` is `127.0.0.1/8 ::1` only. The
`authentik` filter bans the **forwarded** client IP, which for a tailnet user is a `100.64.0.0/10` address, and
the jail declares no `port`, so the ban lands all-ports at `INPUT`. Three failed Authentik logins in an hour from
a tailnet device also kills that device's SSH-over-tailnet for an hour. Recoverable over the public IP, so a
footgun rather than a lockout.
**Options:**
- Leave.
- `services.fail2ban.ignoreIP = [ "127.0.0.1/8" "::1" "100.64.0.0/10" "fd7a:115c:a1e0::/48" ]`.
- Exempt only the `authentik` jail.
**Recommendation:** the fleet-wide `ignoreIP`. The reputation policy (which scores per `(username, ip)`) still catches a compromised tailnet device; the IP ban buys little there. Note the interaction with D-03: if `trusted_proxies` is narrowed, the forwarded IP becomes trustworthy again.

#### D-13 Real workstation FQDNs are still in the public GitHub mirror's history
**Area** Security · **Raised by** desktop · **Severity/effort** Medium / M
**Context:** `nixos-de/modules/home/work-vpn.nix` carried the employer's real workstation FQDNs and Kerberos
realm in a `/cert:tofu` comment, defeating `nixos-de/modules/nixos/work-vpn.nix`'s deliberate sops-encryption of
`rdp_host` ("this repo is on GitHub"). **Removed on this branch** — `grep -rin epic nixos-de/` is now empty —
but the repo is push-mirrored to GitHub, so every prior commit still contains them.
**Options:**
- Accept: the identifiers are internal hostnames, not credentials, and rewriting history breaks every clone and the Forgejo↔GitHub mirror.
- Rewrite history (`git filter-repo`) on both remotes and force-push, then re-establish the mirror.
- Delete and recreate the public GitHub mirror repository from the current tip, abandoning its history.
**Recommendation:** recreate the mirror from the current tip — it is the cheapest option that actually removes them, and the mirror's history has no independent value.

#### D-14 Published container ports bypass the desktop firewall
**Area** Security · **Raised by** desktop (Decision D) · **Severity/effort** Medium / S
**Context:** `nixos-de/modules/nixos/containers.nix` puts `idan` in the `docker` group (root-equivalent), and
dockerd's `DOCKER-USER` chain publishes container ports *around* `networking.firewall`. The firewall otherwise
opens nothing on `enp12s0` except :22, so any `docker run -p 8080:80` is silently LAN-reachable.
**Options:**
- Accept (single-user desktop behind a home router).
- Adopt a convention that every desktop container publishes as `127.0.0.1:PORT:PORT`, and write it down.
- `virtualisation.docker.daemon.settings.iptables = false` — breaks container outbound networking without manual NAT.
**Recommendation:** the documented `127.0.0.1:` convention.

#### D-15 `trustedInterfaces = [ "tailscale0" ]` on both hosts
**Area** Security · **Raised by** desktop (Decision E), vps, nixos-vm · **Severity/effort** Medium / M
**Context:** Set in `nixos-de/modules/nixos/tailscale.nix`, `nixos/modules/network.nix` and
`headscale-vps/configuration.nix`. Every listening socket is exposed to the whole tailnet, not just the intended
ones, so any future `0.0.0.0` bind is silently tailnet-exposed. Safe today because almost everything binds
loopback; `tests/suites/vps.nix`'s curated port sweep is the only guard, and `nixos-de/modules/nixos/sshd.nix`
documents a dependency on the current behaviour.
**Options:**
- Keep (every tailnet peer is a machine you own — until D-05's guest tag exists).
- Replace with explicit `networking.firewall.interfaces.tailscale0.allowedTCPPorts` per host; one line per service.
**Recommendation:** eventually replace, but it is a posture change, not a review fix — sequence it with D-05.

#### D-16 VictoriaLogs' loopback API is unauthenticated for read *and* write
**Area** Security · **Raised by** arch-security (AS-9) · **Severity/effort** Medium / S
**Context:** code-review-2026-08-31 #11 accepted this risk with a marker on `auth_enabled` in
`stacks/logging/loki.yaml`; that file was deleted in the VictoriaLogs swap and the acceptance travelled nowhere.
Every local uid on the services VM — including the Forgejo runner's DynamicUser (D-09) — can query up to
100 GiB / 1 year of both hosts' journals at `127.0.0.1:10456/select/logsql/query`, data it explicitly cannot read
from `/var/log/journal`. **Wider than Loki was:** `/insert/*` shares the port, so a local uid can also poison the
store, which is where fail2ban ban evidence and Authentik `login_failed` events now land.
**Options:**
- Restore the acceptance in `stacks/logging/compose.yaml`'s `ports:` comment with the widened wording (arch-security drafted the text; **in progress — the declarative-apply lane is applying it**).
- Additionally close it with an nftables `meta skuid` match limiting :10456 to root — gatus runs on the host network as root, so its probes still work.
**Recommendation:** the comment alone; the skuid match only if D-09 is left as-is.

### Architecture

#### D-19 Eight stacks carry a byte-identical Postgres block
**Area** Architecture/Stacks · **Raised by** stacks-b (Decision 1) · **Severity/effort** Low / M
**Context:** `stacks/{ghostfolio,outline,dawarich,windmill,tandoor,firefly,excalidraw,paperless}/compose.yaml`
each repeat the same `postgres:17.9-alpine` block modulo user/db name — image, `TZ`, the identical `pg_isready`
healthcheck with identical timings, the same long-form `env_file` — plus five identical `redis:7.4-alpine` blocks.
~120 duplicated lines, and the `pg_isready` "-U is required" comment appears verbatim eight times.
**Options:**
- Leave: each stack directory stays a self-contained artifact the deploy plane can `run_directory` at.
- Shared `stacks/_common/postgres.yaml` + `extends:` — but `extends` resolves relative to the compose file, so `stack-git-sync` would have to materialise `_common/` into every `/srv/stacks/<name>/`, and `mk-stack-suite.nix`'s line-oriented `imageRefs`/`parsedHostPorts` parse would stop seeing the image and port.
- Generate the blocks from Nix, like `nixos/stack-dirs.nix`.
**Recommendation:** leave it. The alternatives break the "one directory = one deployable stack" property both Komodo and the harness depend on, for a cosmetic gain.

#### D-20 Generate the 19 near-duplicate OIDC blueprints
**Area** Architecture · **Raised by** vps (Decision 1) · **Severity/effort** Medium / M
**Context:** All 20 `headscale-vps/authentik/blueprints/custom/*-oidc.yaml` files have an identical non-comment
structure; stripped of comments they differ only in slug, provider name (only vaultwarden deviates, `vaultwarden-sso`),
`!Env` variable, 1-3 `redirect_uris`, display name and description. `headscale-oidc.yaml` is the one genuinely
different file. The failure mode of drift is a silent login break. **Blocker:** `tests/lib/lints.nix`'s
`oidc-contract` globs the blueprints *in the source tree* and opens three by path, so rendering at build time and
deleting the files makes the lint vacuous or a hard error — the files must stay on disk.
**Options:**
- Leave as-is: 19 files x ~46 lines, all hand-edited.
- Generator + committed artifacts + byte-compare lint — exactly the `nixos/stack-dirs.nix` / `stack-dirs-generated` pattern. Add `headscale-vps/authentik/blueprints/generate.py` with a ~19-row table and a `blueprints-generated` lint. ~874 lines of YAML become ~19 table rows plus ~60 lines of generator. Needs a `tests/` change too.
- Render at build time and delete the files — rejected, breaks `oidc-contract`.
**Recommendation:** the generator. This is now the largest remaining drift risk on the VPS.

#### D-21 Rebalance harness coverage toward the fleet's central security claim
**Area** Architecture/Tests · **Raised by** arch-security (S-6) · **Severity/effort** Medium / M
**Context:** The harness is 23.5k lines against 6.3k lines of compose, and it earns its keep — but the imbalance
is in *coverage*, not volume. Of 24 lints, **none** reads `networking.firewall`, and `tests/suites/tailnet.nix`
dials only 3 of ~45 listeners from a real tailnet peer. Samba's 445 and Syncthing's 22000 — the two most exposed
non-loopback listeners in the fleet — are never dialled from a tailnet peer.
**Options:**
- Leave; the curated port sweeps are enough.
- Add a `firewall-declared` lint plus extend the tailnet suite's negative sweep to the full published-port list. A few hundred lines.
**Recommendation:** do it before writing another stack suite — better value per line than more of the same.

### Secrets

#### D-23 `TAILSCALE_AUTH_KEY_OLD` — keep or drop
**Area** Secrets · **Raised by** sops (Decision 1), docs-audit (Q3) · **Severity/effort** Medium / S
**Context:** The key exists in `nixos/secrets.sops.yaml` and `headscale-vps/secrets.sops.yaml` with **zero
references repo-wide** — no `sops.secrets` declaration, no `secrets-gen/manifest.yaml` entry, no mention in the
ServerNotes appendix. Its 48-byte ciphertext matches a real headscale preauthkey, so it is a live credential
sitting unreferenced in two files; it looks like a rollback copy from the 2026-09-06 re-mint. The sops lane made
`sops-declared` green by *adding* it to both `.example`s and three fixtures, which blesses it.
**Options:**
- Keep as a deliberate rollback slot and document it (in the `.example` comments and the deploy-handbook appendix).
- Drop it: `sopseditnvim` both real files, then remove it from `nixos/secrets.sops.yaml.example`, `headscale-vps/secrets.sops.yaml.example` and `tests/fixtures/{services-vm,vps,vps-rotated}.sops.yaml`, then re-run `./tests/run.sh deploy-check`.
**Recommendation:** drop it unless the rollback slot is intentional — an unreferenced live credential is worse than an inconvenient re-mint.

#### D-24 Vestigial Windmill admin keys
**Area** Secrets · **Raised by** sops (Decision 2) · **Severity/effort** Low / S
**Context:** `WINDMILL_ADMIN_EMAIL` / `WINDMILL_ADMIN_PASSWORD` in `stacks/windmill/.sops.env` have been
vestigial since the 2026-09-05 roster rollout — `windmill-init.sh` hardcodes the roster emails and reads
`<USER>_INITIAL_PASSWORD`. They hold a real 32-char password, are unmanaged by `secrets-gen/manifest.yaml` (so
`sopsgen` will never rotate them), and only `tests/suites/windmill.nix` still asserts their presence in the `.env`.
**Options:**
- Drop across all three surfaces (`.sops.env`, `.sops.env.example`, `tests/fixtures/windmill.sops.env` — all together or `stack-env-drift` goes red) plus the suite assertion.
- Add a `manifest.yaml` entry so `sopsgen` at least rotates them.
**Recommendation:** drop them.

#### D-25 Where the trimmed hard-won detail should live
**Area** Secrets/Docs · **Raised by** sops (Decision 3) · **Severity/effort** Low / S
**Context:** The 35 `.sops.env.example` files went from 2,265 to ~1,000 lines. Load-bearing hazards were kept as
one clause each, but some genuinely hard-won analysis went with the cut: vaultwarden's full three-way `$`-quoting
table, firefly's SimpleFIN claim-URL walkthrough, the rmfakecloud `sanitizeEmail` character-class analysis.
**Options:**
- Accept the loss; git history has it.
- Restore selected passages to the `.example` files.
- Move them to `ServerNotes/designs/` (the better home for analysis that is not a per-key instruction).
**Recommendation:** move the three named passages to ServerNotes; leave the examples terse.

#### D-26 `sopsgen rotate user/idan` does not actually rotate four of six consumers
**Area** Secrets · **Raised by** declarative (finding A + Decision 10) · **Severity/effort** High / M
**Context:** `docs/deploy.md` §5.5 says "Edit idan's value once and every one of those follows, hashes included."
True of the sops files, false of the running services. Seed-once consumers: qBittorrent (`qbit-init` exits early
if `qBittorrent.conf` exists), Backrest (`stacks/backrest/config-init.sh` exits early if `config.json` exists),
Beszel (its PocketBase migration fires only against a virgin `data.db`), Windmill (`windmill-init.sh` never resets
an existing password by design). Only `SAMBA_IDAN_PASSWORD` truly rotates. **Second-order damage:** after a
rotation, `stacks/media/.env` carries the new `QBIT_WEBUI_PASSWORD` while qBittorrent holds the old hash, so
`media-init.sh` fails its login (401) and permanently degrades to a `WARN`, and the Radarr/Sonarr download-client
rows keep the old password — imports break, nothing alerts, containers stay healthy. Rewriting the conf in place
is *not* safe: `docker compose up -d` recreates `qbit-init` before stopping qBittorrent, which rewrites the conf
on shutdown. **Partly addressed:** `qbit-init` now *detects and shouts* — four WARN lines naming the cause and the
repair (applied). Backrest, Beszel and Windmill are still silent, and a fifth consumer joins with the last commit:
`JELLYFIN_ADMIN_PASSWORD` is a `user/idan` twin and Jellyfin has no headless password reset, so a rotation there
is a *loud deploy failure* by design rather than a silent drift.
**Options:**
- Documentation only: a "what rotation actually reaches" table in §5.5, and the missing `docs/for-shame.md` row for the qBittorrent case (a WebUI-password rotation needs the conf deleted and the stack redeployed).
- Add the same detect-and-shout guard to Backrest (see D-37's `auth` merge, which fixes it outright), Beszel and Windmill.
- Additionally make `sopsgen rotate` print a post-run report naming targets whose consumers are seed-once.
**Recommendation:** all three. The current wording is the kind of thing that gets trusted during an incident.

#### D-27 An unwired secret knob
**Area** Secrets/Stacks · **Raised by** stacks-a (requests to the sops lane) · **Severity/effort** Low / S
**Context:** `stacks/samba/samba-init.sh` reads `SAMBA_SHARE_GID` with a default of 1000, but the variable is in
no example file and nothing sets it. Adding it means moving `.sops.env` + `.example` + fixture together or
`stack-env-drift` goes red.
**Options:**
- Add `SAMBA_SHARE_GID` to the example as a documented override.
- Drop the indirection and hardcode 1000.
**Recommendation:** drop the indirection — it is in no env file, so this is a script-only edit.

### Stacks

#### D-28 Paperless dependency ordering and healthchecks
**Area** Stacks · **Raised by** stacks-b (Decision 2) · **Severity/effort** Low / S
**Context:** `stacks/paperless/compose.yaml` is the only stack in its lane still using list-form `depends_on`, so
the app starts before Postgres accepts connections and relies on Django's retry. It also ships no healthcheck for
the app container, so the host-side `unhealthy-containers` timer is blind to it — Gatus's loopback probe is the
only signal.
**Options:**
- Leave; it has evidently worked.
- Add `pg_isready` / `redis-cli ping` healthchecks to `db`/`redis`, switch `depends_on` to `condition: service_healthy`, and add an app healthcheck.
**Recommendation:** do it, but as an operator-approved change on a live stack — and pick the probe endpoint deliberately (`/` is an SPA shell; `/api/` needs auth on some versions).

#### D-29 `postgis/postgis:17-3.5-alpine` is a moving tag
**Area** Stacks · **Raised by** stacks-b (Decision 3) · **Severity/effort** Low / S
**Context:** `stacks/dawarich/compose.yaml` is the one image in the fleet whose host-side version can drift
without a compose change, a standing exception to CLAUDE.md's pin-an-explicit-tag rule. `tests/lib/images.nix`
pins the digest, so drift surfaces as a test/host mismatch rather than silently.
**Options:**
- Keep it (no patch-pinned alpine alternative exists; the only more specific 17.x tags are 2024 beta/rc).
- Move to a digest reference in the compose file.
- Move to the non-alpine tag (~1 GB).
**Recommendation:** keep, but record it as a conscious exception rather than an oversight.

#### D-30 `scan-downloads.sh` can quarantine an in-flight download
**Area** Stacks · **Raised by** stacks-a (Decision 2) · **Severity/effort** Low / S
**Context:** `stacks/media/scan-downloads.sh` must scan inside `.incomplete` — qBittorrent *renames* a finished
file out of it and a rename preserves mtime, so a file scanned only at its final path can be older than the
`-newer` marker and never scanned at all (this WHY was undocumented and has been added on this branch). The
consequence is that an infected *partial* file is moved into `.quarantine` mid-download, breaking the torrent
rather than letting it finish and be caught at the final path.
**Options:**
- Leave — an infected partial should not finish anyway; the behaviour fails safe.
- Log-only under `.incomplete`, quarantine at the final path — reopens the mtime coverage hole unless the marker logic is reworked.
**Recommendation:** leave it.

#### D-31 qBittorrent has no Caddy route, but `_overview.md` marks it FwdAuth
**Area** Stacks/Security · **Raised by** stacks-a (Decision 3) · **Severity/effort** Low / M
**Context:** qBittorrent's UI rides gluetun's `127.0.0.1:10057`; `stacks/caddy/Caddyfile` records the missing route
as deliberate because the Authentik blueprint entry does not exist yet, and flipping the route first is the
documented lockout hazard. The blueprint entry and the route must land in one change.
**Options:**
- Add the `qbittorrent-oidc` blueprint and the protected Caddy handle together, then update `_overview.md`.
- Correct the `_overview.md` Auth cell to `--` and leave it loopback-only.
**Recommendation:** an operator/VPS sequencing decision — but the row and the reality must agree either way.

#### D-32 Paperless — the superuser-group variable needs an image bump past 2.20
**Area** Stacks/Security · **Raised by** declarative-apply (Not applied / Decision 2), declarative (Decision 1) · **Severity/effort** Medium / M
**Context:** `PAPERLESS_SOCIAL_ACCOUNT_SYNC_SUPERUSER_GROUP` would replace the manual `/admin` grant, but it
**does not exist at the pinned tag**. Re-verified by fetching the tags: absent from v2.20.0, v2.20.15 and v3.0.0
(`src/paperless/settings.py` has only `SOCIAL_ACCOUNT_DEFAULT_GROUPS` and `SOCIAL_ACCOUNT_SYNC_GROUPS`, and
`handle_social_account_updated` has no `is_superuser` branch); it first appears in **v3.1.0**. `stacks/paperless/compose.yaml`
pins `2.20`. Setting it now would be a silent no-op that also invited deleting the for-shame entry.
`PAPERLESS_SOCIAL_ACCOUNT_SYNC_GROUPS` is not a substitute — it only sets Django group membership, which grants
neither `is_superuser` nor `is_staff`. And when it does land it is not "grant once": it re-evaluates on every
social login and sets `is_superuser = False` when the group is absent, with no last-admin exemption, so a changed
property mapping demotes the SSO user (break-glass: `PAPERLESS_ADMIN_USER` is a separate local superuser the
handler never touches).
**Options:**
- Bump the pin to ≥3.1 and then set the variable — a 2.20 → 3.x major with its own migration surface, and it needs `./tests/update-images.sh` plus a `./tests/run.sh paperless` run.
- Keep the manual `/admin` grant, which is a one-shot that cannot regress but must be redone on every DB rebuild.
**Recommendation:** keep the manual grant until a Paperless major bump is wanted for its own sake; do not bump the image just for this.

#### D-33 Vaultwarden — the SSO signup posture is now explicit; flip it or keep it
**Area** Stacks/Security · **Raised by** declarative-apply (Decision 3), declarative (Decision 2) · **Severity/effort** Medium / S
**Context:** `SSO_SIGNUPS_ALLOWED=true` is **written explicitly on this branch**, along with a corrected comment —
verified at the pinned 1.37.2 that `config.rs`'s `is_sso_signup_allowed` reads only `sso_signups_allowed` (default
`true`) and the domain whitelist, so `SIGNUPS_ALLOWED=false` never gated it and the `/admin`-invite step was
already redundant. Any Authentik identity could always create a row. Only the browser master-password step is
irreducible (E2EE). So the variable is no longer implicit; the posture itself is still a choice.
**Options:**
- Keep `true` — the Authentik user list is the gate, with `SIGNUPS_DOMAINS_WHITELIST` available as a second belt.
- Flip to `false` and reinstate the `/admin` invite as the gate on who gets a vault.
**Recommendation:** keep `true`. With 7 trusted users on a tailnet, a second gate buys little; the value delivered was writing it down.

#### D-34 BookStack — an Authentik group named `Admin` grants BookStack admin
**Area** Stacks/Security · **Raised by** declarative-apply (Decision 4), declarative (Decision 3) · **Severity/effort** Low / S
**Context:** `OIDC_USER_TO_GROUPS=true` + `OIDC_GROUPS_CLAIM=groups` are **applied** in
`stacks/tracking/compose.yaml` (`OIDC_REMOVE_FROM_GROUPS` deliberately unset), verified against
`GroupSyncService`: it matches an IdP group name against each role's `display_name` lowercased/hyphenated and does
not exclude the built-in Admin role, whose display name is `Admin`. So group membership *is* BookStack admin, and
it re-asserts after a rebuilt MySQL volume. The matching `authentik_core.group` (`id: group-admin`, `name: Admin`)
is **also applied** in `headscale-vps/authentik/blueprints/custom/headscale-oidc.yaml` with idan in it, so the
manual promote-to-admin step is gone and its for-shame row with it. What remains a standing decision is the shape:
a group literally named `Admin` is a fleet-wide privilege handle that any future display-name-matching app would
also pick up.
**Options:**
- Keep it (current state) — nothing manual, at the cost of a shared privilege handle. Its purpose is named in the blueprint comment so the coupling is visible.
- Rename to `bookstack-admins` and set BookStack's Admin role External Authentication ID to match — but that field is set in the BookStack UI, reintroducing a one-time manual step elsewhere.
- Revert `OIDC_USER_TO_GROUPS` and go back to promoting by hand.
**Recommendation:** keep it. Revisit only if a second app starts matching group display names, which is exactly what the blueprint comment exists to catch.

#### D-35 Jellyfin — auto-create the admin from sops, or keep the wizard
**Area** Stacks · **Raised by** declarative-apply (Decision 5), declarative (Decision 4) · **Severity/effort** Medium / M
**Context:** The full sidecar is **implemented in the branch's last commit** (`stacks/media/jellyfin-init.sh` +
`jellyfin-encoding.xml` + the Seerr and Bazarr seeds), so accepting that commit *is* taking this decision. It was
proven end to end offline: the media suite logged the wizard, the admin, both libraries, and Seerr syncing those
same libraries back. Consequences to accept knowingly: the admin password becomes a sops value in the `user/idan`
twin fan-out, and Jellyfin has **no headless password reset** — so `sopsgen rotate user/idan` after the first
Jellyfin deploy changes what the init *logs in with*, not what Jellyfin *stores*, and the next deploy fails loudly
(reset in the UI or wipe `/mnt/fast/jellyfin/config` first). Seerr authenticates against the same account.
**Options:**
- Take the whole thing (current state of the last commit).
- Reduce to `jellyfin-config-init` + `jellyfin-encoding.xml` only — hardware transcode, independently valuable, no credential coupling. That half is separable from the rest of the patch.
- Revert both and keep the wizard as a deliberate human act, accepting that it is then a two-service manual step.
**Recommendation:** take the whole thing — bring-up from the repo is the stated goal, and the rotation caveat fails loudly rather than silently.

#### D-36 Actual — automate the OIDC DB flip?
**Area** Stacks · **Raised by** declarative (Decision 5) · **Severity/effort** Low / S
**Context:** `docker exec actual node scripts/enable-openid.js` is a documented manual step and *is* automatable
(`actual_init` runs on the same image; add `/mnt/fast/actual:/data` plus a guard on `GET /account/needs-bootstrap`).
What stays irreducible is the consequence: the first OIDC login becomes the server owner permanently, and on a
tailnet that is whichever enrolled device gets there first.
**Options:**
- Automate the flip and accept a race the operator must win by logging in promptly after a deploy.
- Keep it manual so the flip and the first login are one deliberate act.
**Recommendation:** keep it manual — this is the one place where the manual step *is* the safety mechanism. Add "automating the flip would make the ownership race start at deploy time" to the for-shame entry, which currently reads as if no automation existed.

#### D-37 Backrest — is `config.template.json` a seed or a source of truth?
**Area** Stacks/Backups · **Raised by** declarative (Decision 6 + finding B) · **Severity/effort** Medium / M
**Context:** `stacks/backrest/config-init.sh` writes `config.template.json` exactly once. The file carries the
entire backup policy — repos, plans, retention, excludes, hooks — so adding a plan or changing retention in the
repo does **not** reach an already-deployed host; it only affects a fresh volume. The file reads as declarative
and is not. Backrest's UI writes the same file, so a whole-file re-render would fight it.
**Options:**
- Leave it a seed and document that loudly.
- Merge only `auth.users[].passwordBcrypt` on every start — small, fixes the D-26 rotation gap for Backrest, cannot surprise anyone.
- Merge `auth` + `repos` + `plans` (the `kavita-config-init` shape) and declare the UI advisory for those subtrees.
**Recommendation:** the `auth` merge now, the fuller merge later — the latter needs a decision about who owns the retention policy.

#### D-38 Beszel — should the OIDC provider be PATCHed in too?
**Area** Stacks · **Raised by** declarative-apply (Not applied), declarative (Decision 7) · **Severity/effort** Low / M
**Context:** The `role` half is **fixed on this branch** — new `stacks/beszel/beszel-role.sh` plus a `beszel-role`
oneshot gated on the hub being healthy, and the suite caught the real bug live
(`CHANGE: app user … promoted from 'user' to 'admin'`). The remaining half is the double login: Beszel's OIDC setup
is a browser wizard, and a superuser `PATCH /api/collections/users` with an `oauth2.providers` entry would persist
and remove the second *password* login. It was **not** applied because it needs `BESZEL_OIDC_CLIENT_SECRET` in
`stacks/beszel/.sops.env` twinned into `headscale-vps/secrets.sops.yaml`, plus a new `beszel-oidc.yaml` Authentik
blueprint — neither in the lane's paths, so it could not ship self-contained.
**Options:**
- Leave the two logins. Forward auth still fronts the hub; the second login is a browser-only annoyance.
- Add the sidecar, the cross-host secret twin and the blueprint. Note the Caddyfile's rejection of `TRUSTED_AUTH_HEADER` is sound and should stand either way.
**Recommendation:** leave it until the double login actually annoys — the role bug it was bundled with is already fixed.

#### D-39 Publish `grafana-vlogs` and switch the logging stack's pin?
**Area** Stacks · **Raised by** declarative-apply (Decision 1), declarative (Decision 8), docs-audit (gap F) · **Severity/effort** Low / S
**Context:** The plugin image is **built on this branch** — `stacks/logging/Dockerfile` plus
`.github/workflows/build-grafana-vlogs.yml`, mirroring the `stacks/caddy` precedent (composite
`<grafana>-vl<plugin>` tag greped out of the Dockerfile, both versions pinned, no mutable tag). It is
**unreferenced**: `stacks/logging/compose.yaml` still pins `grafana/grafana:13.2.0` with the interim host-side
recipe, because the built tag does not exist until the workflow has run once and pointing at it now would break
every deploy. The host-side alternative (`GF_PLUGINS_PREINSTALL_SYNC` + a zip under `/mnt/fast`) was rejected: it
needs a new `/mnt` bind source, i.e. a `nixos/stack-dirs.nix` regeneration, and still leaves a manual `curl`.
**Options:**
- Run the workflow once, then move the `image:` to `ghcr.io/idanreed/grafana-vlogs:13.2.0-vl0.31.0` and add an `update-images.sh` substitution mapping it to plain `grafana/grafana:13.2.0` for the offline suites (exactly what `caddy-cloudflare` does). Deletes the for-shame entry.
- Leave the Dockerfile and workflow dormant and keep the host-side install.
- Delete both and accept the manual step permanently.
**Recommendation:** publish and switch — the build already exists, so the remaining cost is one workflow run plus one substitution line.

#### D-40 Firefly III — the headless PAT mint does not exist in the image
**Area** Stacks · **Raised by** declarative-apply (Not applied / Decision 6) · **Severity/effort** Low / S
**Context:** `declarative.md` proposed minting the importer's Personal Access Token with
`php artisan tinker --execute`. Re-verified at the pinned tag and the conclusion does not hold: `laravel/tinker`
is not a Firefly III dependency (it appears in `composer.lock` only as a `suggest` string, and `psy/psysh` is
absent), the sole `createToken` call sits behind a browser session in
`app/Http/Controllers/Profile/OAuthController.php`, and `correction:access-tokens` mints the command-line token
the importer's own `.env.example` warns against. The other half **is** solved: the branch's last commit persists
the Passport RSA keypair from sops, so a hand-minted token stops being invalidated on every container recreate.
**Options:**
- Keep the mint manual and amend the `docs/for-shame.md` entry to say why (no tinker in the image, browser-only `createToken`) rather than deleting it.
- Hand-roll a Laravel console bootstrap in a sidecar off the same image (`vendor/autoload.php` + `bootstrap/app.php` + the console kernel) reaching into `Laravel\Passport\ClientRepository` — unsupported internals, unverifiable offline, and it would run on every deploy holding a full-access token.
**Recommendation:** keep it manual and amend the entry. With the keypair persisted, most of the pain is already gone.

#### D-41 Immich — leave `IMMICH_ALLOW_SETUP` unset
**Area** Stacks · **Raised by** declarative (Decision 9) · **Severity/effort** Low / S
**Context:** Immich 3.x added `IMMICH_ALLOW_SETUP` (default `true`), gating both `POST /api/auth/admin-sign-up`
and `/admin/database-backups/start-restore`. Setting it `false` after bootstrap closes a restore endpoint — but
would also stop `immich-init` re-seeding after a volume wipe, which is exactly the from-repo property the fleet
is chasing. `admin-sign-up` is already gated on `!hasAdmin()`.
**Options:** leave unset (`true`); or set `false` post-bootstrap and accept the re-seed loss.
**Recommendation:** leave unset. Residual exposure is the restore endpoint on a loopback-bound port behind Caddy.

### NixOS hosts

#### D-42 The stale MAC in `10-lan.link`
**Area** NixOS hosts · **Raised by** nixos-vm (Decision 1) · **Severity/effort** Low / S
**Context:** `nixos/modules/network.nix` pinned `a2:db:6f:f6:9f:d7`, but `nixos/flake.nix` bakes
`net0 = virtio=BC:24:11:5E:11:03` into the VMA and `qmrestore` resets the VM to it on every re-image — so after
any re-image the Match failed and the pin was dead code. The link now matches **both**
(`MACAddress=a2:db:6f:f6:9f:d7 bc:24:11:5e:11:03`).
**Options:**
- Leave the pair — safe under any state.
- Once `ip link show ens18` on 10.0.0.3 confirms the live MAC, keep only that one.
- If the live VM still reports `a2:db:…`, also run `qm set <id> --net0 virtio=BC:24:11:5E:11:03,bridge=vmbr0,firewall=1` so the two agree before the next re-image.
**Recommendation:** keep the pair now; converge at the next maintenance window.

#### D-43 `bootstrap-komodo`'s bare `sleep 5`
**Area** NixOS hosts · **Raised by** nixos-vm (Decision 2) · **Severity/effort** Low / S
**Context:** `nixos/modules/deploy-plane.nix` sleeps 5 seconds before `docker compose up -d`, although the unit
already `Requires=`/`After=` docker.service, srv.mount, `stack-env-publish` and `docker-network-homelab`. What the
sleep buys is unexplained, and there is no `--wait` and no retry, so a failed bring-up does not fail the unit and
never reaches ntfy.
**Options:** leave it; drop it; or replace with `docker compose up -d --wait` plus a `TimeoutStartSec`.
**Recommendation:** `--wait` + timeout, but only alongside a `./tests/run.sh gitops` run — it changes when the unit is considered started.

#### D-44 `tmpfiles.d` rule order moved (cosmetic)
**Area** NixOS hosts · **Raised by** nixos-vm (Decision 3) · **Severity/effort** Low / S
**Context:** The module split moved `/var/lib/backup` two rules earlier in `systemd.tmpfiles.rules`, because
module definitions merge before `nixos/hardware-configuration.nix`'s. Same 170 rules, distinct paths,
`d`-before-`C+` preserved; verified as the only system-wide difference the split produced.
**Options:** accept; or wrap the pair in `lib.mkAfter` to restore the exact previous order.
**Recommendation:** accept.

#### D-45 `nixos-de/disko.nix` `targetDisk` is still `CHANGE_ME_TO_YOUR_DRIVE_ID`
**Area** NixOS hosts · **Raised by** desktop (Decision A) · **Severity/effort** Medium / S
**Context:** The running desktop's `/` is `nvme2n1p2` with partlabels `disk-main-ESP` / `disk-main-root` — this
exact disko config partitioned the machine — but the committed `targetDisk` was never filled in. The other two
NVMe drives hold Windows partitions, so a *wrong* value wipes the Windows install.
**Options:**
- Fill in the by-id path of the live root disk (serial-qualified, stable). Operator must confirm the serial.
- Leave `CHANGE_ME` as a deliberate fail-safe and say so in the comment.
- Drop `disko.nix` from `nixosConfigurations.desktop` and keep it as an install-only artifact.
**Recommendation:** fill it in. The placeholder is not protective — it makes the committed config unable to reproduce the machine.

#### D-46 nixfmt adoption
**Area** NixOS hosts/Tests · **Raised by** desktop (Decision B), tests (Decision 5) · **Severity/effort** Low / M
**Context:** `nixfmt --check` flags 11 of 34 files under `nixos-de/`; adopting it would reformat `niri.nix`'s
hand-aligned bind table and `nixvim.nix`'s compact keymap lists. `nixos-de/test.sh` now actually runs nixfmt
(previously silently skipped) but keeps it non-fatal. Separately, `tests/{default,lib/lints,lib/mk-stack-suite,lib/profiles}.nix`
all fail `nixfmt-rfc-style --check` identically on `main` — pre-existing, and `tests/` is not in any formatting gate.
**Options:**
- Leave non-fatal everywhere (status quo).
- One mechanical `nixfmt -w` commit over `nixos-de/` and make the step fatal (~500 lines of whitespace).
- Also reformat `tests/` (~2000 lines of churn) and add it to a gate.
- Delete the nixfmt step entirely.
**Recommendation:** leave non-fatal now; if adopted, do it as a separate mechanical commit that does not ride along with a review.

#### D-47 Keep `nixos-de/statix.toml`?
**Area** NixOS hosts · **Raised by** desktop (Decision C) · **Severity/effort** Low / S
**Context:** New file on this branch. It disables `repeated_keys` and `empty_pattern`, the only two classes statix
fired (19 + 5 warnings, all stylistic), so statix is now clean and actually gates — a real regression will stand
out. Satisfying them instead means grouping `services.*`/`security.*`/`systemd.*` into nested attrsets and writing
`_:` instead of `{ ... }:` for argument-less modules.
**Options:** keep the config; delete it and restructure the modules; delete it and go back to statix being noise.
**Recommendation:** keep it. Flat dotted paths are the NixOS idiom and merge identically; `{ ... }:` self-documents that a file is a module.

#### D-48 Delete `headscale/cloud-init.yml`
**Area** NixOS hosts/Docs · **Raised by** vps (Decision 4) · **Severity/effort** Low / S
**Context:** 218 lines, superseded by `headscale-vps/`, referenced by nothing in the repo. It pins
`headscale/headscale:latest` and `coredns/coredns:latest`, and its `dns.nameservers.global` pointing at a CoreDNS
box is *exactly* the failure `headscale-vps/modules/headscale.nix` documents as a past outage — so it is not just
stale, it is actively misleading as a reference. `ServerNotes/issues/code-review-2026-08-31.md` still tracks "only
headscale/cloud-init.yml remains".
**Options:** keep (CLAUDE.md says "kept for reference"); or delete, as `flatcar/` already was — git history retains it.
**Recommendation:** delete, and update CLAUDE.md's "Legacy directories" paragraph.

### Tests/CI

#### D-49 Pin `nix-prefetch-docker` to the harness's nixpkgs
**Area** Tests/CI · **Raised by** tests (Decision 1) · **Severity/effort** Low / S
**Context:** Everything in `tests/` is pinned from `headscale-vps/flake.lock`, but `tests/update-images.sh`
resolves `nix-prefetch-docker` from the flake registry. Fix is one line (`nix-build tests -A pkgs.nix-prefetch-docker`).
**Options:** pin it — cost is that `update-images.sh` then fails whenever `tests/` fails to evaluate; or leave it.
**Recommendation:** pin it; a pin generator resolving its own tool from an unpinned registry is the drift the harness exists to prevent.

#### D-50 An `images-generated` drift lint
**Area** Tests/CI · **Raised by** tests (finding + Decision 2) · **Severity/effort** Low / M
**Context:** `tests/lib/images.nix` has no generated-file drift lint. Its header describes a substitution table
that no longer matches `update-images.sh` — header and body cannot have come from one run, so the file was
hand-edited or the table changed without regenerating. `nixos/stack-dirs.nix` has `stack-dirs-generated` for
exactly this shape of risk.
**Options:** add the lint (prerequisite: a clean `update-images.sh` run, which hits registries and churns digests); or leave it.
**Recommendation:** add it the next time somebody regenerates pins anyway.

#### D-51 Reshape `images.nix` to `{ pins; _unresolved; _skipped; }`
**Area** Tests/CI · **Raised by** tests (Decision 3) · **Severity/effort** Low / S
**Context:** `images.nix` is a mixed-type attrset — `_unresolved`/`_skipped` (lists) sit beside the image entries,
and each consumer strips them differently (`removeAttrs` in `tests/lib/lints.nix`, `filter isAttrs` in
`tests/lib/mk-stack-suite.nix`). A nested shape removes both workarounds: one generator change plus two call sites.
Same prerequisite as D-50 (it rewrites the file).
**Options:** reshape; or leave the two workarounds.
**Recommendation:** bundle with D-50 into one regeneration commit.

#### D-52 Renovate cannot bump the plugin half of the Caddy composite tag
**Area** Tests/CI · **Raised by** tests (Decision 4) · **Severity/effort** Low / M
**Context:** The `caddy-fork-tag` manager in `renovate.json` was broken (it could never resolve an upgrade, and had
it fired it would have destroyed the composite tag) and **is fixed on this branch** — caddy bumps now rewrite the
`2.11.2` half correctly. A **plugin-only** bump (`cloudflare@v0.2.5`) still has to move the `-cf0.2.4` half in
`stacks/caddy/compose.yaml`, and no manager writes that; it is a hand edit the Dockerfile header asks for.
**Options:** leave the gap documented in the manager's `description` (done); or wire a second custom manager (a go datasource writing into a docker tag — fiddly).
**Recommendation:** leave it documented; plugin bumps are rare enough.

#### D-53 Nothing notifies when the nightly heavy suite fails
**Area** Tests/CI · **Raised by** tests (Decision 6) · **Severity/effort** Low / S
**Context:** `.forgejo/workflows/heavy-nightly.yml` runs for ~6 hours and nothing alerts on failure — the fleet's
ntfy path covers systemd units, not Forgejo Actions. `workflow_dispatch:` was added on this branch so a failure is
at least re-runnable, but silence is still the default outcome.
**Options:** add a `curl` step posting to ntfy on failure (interacts with D-02's token plan); accept silence; or move the nightly to a systemd timer on the VM, which already has ntfy `OnFailure` wiring.
**Recommendation:** an ntfy step on failure — the cheapest of the three.

#### D-54 `.gitignore`'s `*.claude` hides every shared `.claude/` file
**Area** Tests/CI/Docs · **Raised by** desktop (request), security-apply (Decision 1, deliberately not applied) · **Severity/effort** Low / S
**Context:** `.gitignore`'s first line is `*.claude`, which ignores the entire `.claude/` directory everywhere in
the repo — so a *shared* `.claude/settings.json`, `.claude/agents/` or `.claude/commands/` can never be committed,
while `.claude/worktrees/` and per-machine `settings.local.json` (which hold ad-hoc permission allowlists) are
correctly excluded. Narrowing the pattern is a repo-wide behaviour change that would immediately start tracking
files nobody has reviewed, which is why the security-apply lane left it alone.
**Options:**
- Leave it; keep all Claude Code configuration per-machine.
- Narrow to `.claude/settings.local.json` + `.claude/worktrees/`, then review and commit whatever surfaces (`git status --ignored` first, so nothing lands unexamined).
- Narrow and simultaneously add explicit `!` re-includes for only the files intended to be shared.
**Recommendation:** narrow, but run `git status --ignored` before the first commit after the change — the point is to make settings shareable, not to sweep up whatever happens to be on disk.

### Docs

#### D-55 `--sudo` vs `--use-remote-sudo`
**Area** Docs · **Raised by** docs-audit (Q1, section D) · **Severity/effort** Low / S
**Context:** The code uses `--use-remote-sudo` everywhere (`deploy`, `nixos-de/home.nix`'s `nrs-vps`,
`nixos/build_proxmox.sh`, `headscale-vps/deploy.sh`). `docs/deploy.md` says `--sudo` is the modern spelling and
`ServerNotes/designs/deploy-handbook.md` uses both spellings in different sections. `--use-remote-sudo` is a
deprecated alias in the pinned nixpkgs but still works.
**Options:** standardise the docs on `--use-remote-sudo` (matches the code); or change the code to `--sudo` and standardise on that.
**Recommendation:** standardise docs on the code's spelling now; revisit if the alias is ever removed upstream.

#### D-56 Retire the log-style docs
**Area** Docs · **Raised by** docs-audit (Q4-Q7, Q9, log-style table) · **Severity/effort** Low / M
**Context:** Several documents are point-in-time logs living in a designs directory. The two inside this repo —
`LONGRUN-STACKS.md` (23 lines) and `nixos-de/AGENT_REVIEW_WORKFLOWS.md` (257 lines) — were **deleted on this
branch** by the docs lane. What remains needs an owner decision because it lives in ServerNotes:
`ServerNotes/designs/DOC-DRIFT-REPORT.md` (its one cross-ref is wrong), `main-verification-status.md` (its central
claim — `sops-declared` is red by design — is now false), and `_todo.md`, whose own banner says its checkboxes are
wrong and to trust `deploy-status.md`. Separately, `deploy-handbook.md` §2.2 narrates a registrar transfer as pending.
**Options:**
- Delete them; git history retains everything.
- Move to `ServerNotes/notes/` with a superseded header.
- Keep and commit to reconciling `_todo.md` against `deploy-status.md`.
**Recommendation:** move the two design docs to `notes/` with a superseded header, and retire `_todo.md` in favour of `deploy-status.md`. Confirm the registrar transfer completed and delete §2.2 outright rather than moving it.

#### D-57 README service tables duplicate `_overview.md`
**Area** Docs · **Raised by** docs-audit (Q10) · **Severity/effort** Low / S
**Context:** The repo READMEs carry service tables including an auth column, duplicating
`ServerNotes/designs/_overview.md`, with no lint covering them. They will drift; `_overview.md` is the authority.
**Options:** keep the duplication as a nice front door and accept drift; generate the tables from `_overview.md`; or replace them with a pointer.
**Recommendation:** replace with a pointer — a generated table is a fourth generated artifact for a front page.

#### D-58 DocSpace's auth method is contradicted in three places
**Area** Docs/Stacks · **Raised by** docs-audit (Q12) · **Severity/effort** Low / S
**Context:** `ServerNotes/designs/_overview.md` says `SAML`, and the (now-deleted) `LONGRUN-STACKS.md` recorded
that row being deliberately *corrected* from OIDC to SAML — but `stacks/docspace/compose.yaml` configures no SSO
at all and its Caddy handle has no `import protected`. The new `auth-coverage-required` lint accepts the handle
via an `UNAUTHENTICATED_OK` entry citing SAML — but nothing checks a non-`FwdAuth` cell in `_overview.md` against
the stack, so the row and the reality can still disagree indefinitely.
**Options:** local accounts only — fix the `_overview.md` row to `Local`; or wire SAML in the stack as the row claims.
**Recommendation:** fix the row to match reality now; treat SAML as a separate piece of work.

#### D-59 `_overview.md` has a fully-populated row for a service that does not exist
**Area** Docs · **Raised by** docs-audit (Q13) · **Severity/effort** Low / S
**Context:** The `qbit_manage` row carries a port, volume and auth method, but no such service exists anywhere in
`stacks/`, and it has no Planned marker. `overview-sync` does not catch it because rows are matched from the code
side, not the doc side.
**Options:** mark it Planned; delete the row; or add the service.
**Recommendation:** mark it Planned — that is what the marker is for.

#### D-60 `AA_MIRROR_URLS` is consumed but unmanaged
**Area** Docs/Secrets · **Raised by** docs-audit (Q14) · **Severity/effort** Low / S
**Context:** `stacks/books/compose.yaml` consumes `AA_MIRROR_URLS`, but it has no `secrets-gen/manifest.yaml`
entry, so `sopsgen` will never prompt for it and it is invisible to the deploy runbook's inventory. It is one of
the values the sops lane classified as "deliberately empty".
**Options:** add a manifest entry (the runbook then inherits it for free); or document it as an intentionally-empty knob.
**Recommendation:** add the manifest entry with `class: pull` — it is exactly the shape the manifest is for.

#### D-61 Should `docs/for-shame.md` be generated from `secrets-gen/manifest.yaml`?
**Area** Docs · **Raised by** docs-audit (Q15), declarative · **Severity/effort** Medium / M
**Context:** The manifest's `class: pull` + `reminder:` fields are already a more complete and machine-checked
wall of shame (18 entries vs 1 overlapping). Maintaining both by hand guarantees divergence — and they already
have: the declarative lane found three for-shame entries stale (Home Assistant and Homebox are already automated,
Vaultwarden's `/admin` invite is overstated) and four real manual steps missing (Grafana's plugin, Proton's
interactive `hydroxide auth`, Cleanuparr's arr connections, Samba's LAN exposure edits).
**Options:**
- Generate the wall from the manifest and keep hand-written entries only for non-secret manual steps.
- Keep it hand-written but add a lint asserting every `class: pull` entry appears.
- Keep both by hand and fix the drift once (see the applied-list note).
**Recommendation:** add the lint. Generating loses the prose that makes the wall useful; a lint kills the divergence.

#### D-62 Lint the `_overview.md` Volume and Notes columns
**Area** Docs/Tests · **Raised by** docs-audit (Q16, sections A-E) · **Severity/effort** Medium / M
**Context:** `overview-sync` already parses the table but reads only some columns: the **Volume** column is read by
no lint at all (11 cells are wrong), the Notes column is never parsed, rows with no 4-5-digit port are invisible to
every lint, and the image rule is whole-file rather than service-scoped. The Auth column's non-`FwdAuth` rows are
also still unchecked: the new `auth-coverage-required` lint closed the Caddyfile direction (every handle must be
protected, in an OIDC blueprint, or exempt with a reason), but a row *claiming* `Local`, `OIDC` or `--` is still
compared against nothing — which is how D-58's DocSpace contradiction survives.
**Options:** extend `overview-sync` to Volume + Notes and make the image rule service-scoped; add the Auth-cell reverse leg (a row claiming OIDC must have a blueprint, a row claiming `--` must be in `UNAUTHENTICATED_OK`); extend only Volume (the column with real drift); or leave the table advisory below the port/image columns.
**Recommendation:** extend to Volume at least — the parser is already there and volumes are what a restore depends on.

#### D-63 Fill the bring-up steps that are documented nowhere
**Area** Docs · **Raised by** docs-audit (section F) · **Severity/effort** Medium / M
**Context:** Nine real bring-up steps appear in neither runbook: Forgejo Actions runner registration (without it
"Renovate PRs can never go green"), the Renovate PAT and first run, nested virt on the Proxmox host (`/dev/kvm` in
the guest, else `kvm`-labelled CI jobs fail), GitHub push-mirror setup, `secrets-recovery.sops.yaml` as a recovery
artifact, the Grafana datasource plugin (D-39), headscale `extra_records` for `auth.idanreed.com` (skipping it
silently degrades three Gatus probes), Proton's interactive `hydroxide auth`, and Samba's two LAN-exposure edits.
**Options:** add all nine to the canonical runbook; add only the three that silently break things (runner registration, nested virt, `extra_records`); or leave them to tribal knowledge.
**Recommendation:** add all nine — a from-scratch runbook that omits a step is worse than no runbook.

#### D-64 The VPS and desktop READMEs contain instructions that will break a fresh install
**Area** Docs · **Raised by** docs-audit (section A, D) · **Severity/effort** Medium / M
**Context:** `headscale-vps/README.md` tells the operator to create `headscale users create idan` as the first
tailnet user — which directly contradicts the canonical runbook and reproduces the duplicate-`idan` lockout
learned live on 2026-09-06 — to hand-edit `authorizedKeys` (built from `ssh-pubkeys.nix`, and the parity lint would
fight it), to `export SOPS_AGE_KEY_FILE=../sops_age_key.txt` (against the fleet rule that the key never enters the
workspace), and specifies a Hetzner plan that no longer exists with half the RAM Authentik needs.
`nixos-de/README.md` lists a `modules/nixos/sops.nix` that does not exist, describes a root-level `.sops.env.example`
that does not exist, omits the home-manager bootstrap so its documented post-install step fails, omits joining the
tailnet entirely, and carries a dead Tailscale-SaaS MagicDNS URL that leaks a decommissioned tailnet name.
**Options:** rewrite both READMEs against the canonical runbook; reduce them to a pointer plus host-specific notes; or delete them.
**Recommendation:** reduce to a pointer plus host-specific notes — duplicated runbooks are how the duplicate-`idan` hazard got written down twice, differently.

---

## Accepted risks (documented, no action)

- **AS-16 — No off-host age-key escrow.** `ServerNotes/designs/core-disaster-recovery.md` §1.1 already calls this
  the largest unmitigated risk. Two details it does not say: `secrets-recovery.sops.yaml` is encrypted to the *same*
  production recipient, so it is not an escrow against age-key loss; and it holds `STORAGE_BOX_SUB_ACCT_PASSWORD`,
  putting the backup-destination credential in the same failure domain as `RESTIC_PASSWORD`. The operator to-do
  above is the mitigation; the doc needs the correction either way.
- **AS-17 — Syncthing's 22000 reaches the IoT VLAN.** `stacks/notes-sync/compose.yaml` publishes `22000/{tcp,udp}`
  on 0.0.0.0 with a named exemption in `loopback-binding` that reasons correctly about the LAN. `_overview.md`'s
  network section says the IoT VLAN can reach 10.0.0.3 wholesale, so 22000 is reachable from the least-trusted tier
  too. Low: BEP is mutually authenticated by device certificate first. One sentence should be appended to the
  exemption text in `tests/lib/lints.nix` (**not yet applied**).
- **AS-18 — The cloud-init age key persists inside the guest.** `nixos/build_proxmox.sh` writes the key into a
  Proxmox snippet (now 0600 root, fixed on this branch) and attaches it via `--cicustom`. The cloud-init drive
  stays attached and cloud-init caches the userdata at `/var/lib/cloud/instance/user-data.txt` in the guest. Low
  (`/dev/sr0` is 0660 root:cdrom and `docker` is already root-equivalent there) — but it means the services-VM key
  would still be recoverable from the guest even if D-01 lands. Fix is one line in the script's closing notes:
  after the second boot, `qm set <VMID> --delete cicustom`, remove the snippet, and `rm -f` the guest cache.
- **Forgejo's OIDC client secret on argv.** `stacks/forgejo/forgejo-init.sh` runs `forgejo admin auth add-oauth
  --secret "$SECRET"` (and `update-oauth`), putting `FORGEJO_OIDC_CLIENT_SECRET` in `/proc/<pid>/cmdline`.
  Verified against upstream, not assumed: `cmd/admin_auth_oauth.go` declares `secret` as a bare
  `cli.StringFlag` — no `--secret-file`, no `EnvVars` — and the DB-backed auth source has no non-CLI route in
  Forgejo 16.0. Exposure is a short-lived one-shot container whose reader is already root-equivalent, and the
  secret is already on the host in `.env`. ACCEPTED note applied to the script header.
- **Syncthing's GUI password on argv.** `stacks/notes-sync/compose.yaml`'s `syncthing_generate` passes
  `--gui-user`/`--gui-password`. Verified: syncthing 2.x has env vars for `STGUIADDRESS` and `STGUIAPIKEY` but
  none for the GUI credentials, and `syncthing generate` takes them as flags only. The only alternative is
  hand-writing a bcrypt hash into `config.xml`, which would also have to reproduce the cert/key half the command
  exists for. ACCEPTED note applied. (`stacks/tracking/bookstack-admin-init.sh` is the same class and was already
  accepted in code-review-2026-08-31.)
- **`wheelNeedsPassword = false` + `trusted-users = [ "@wheel" ]`** on both hosts: a compromised authorized key is
  instant root. Pre-existing, documented in both `configuration.nix` files, unchanged.
- **`rateLimitBurst = 0` with `SystemMaxUse=512M`** on the VPS: an attacker who can generate log volume rotates
  fail2ban's ban evidence out faster than the rate limiter would have dropped it. Deliberate;
  `headscale-vps/modules/log-shipper.nix` is the mitigation (evidence leaves the box).
- **Headscale blueprint re-asserts user passwords on every apply**, so a user's own password change reverts on the
  next deploy. Already a recorded decision.
- **`stacks/docspace/compose.yaml` runs the portal as `user: root`**, following upstream. The entrypoint rewrites
  `/etc/nginx` and `/app/onlyoffice/config` before dropping into supervisord, so dropping privileges needs real
  testing.

---

## Applied on this branch (for reference)

Functional and security fixes already in the tree. Everything else in the diff is comment/structure work.

- **nixos-vm** — `grow-disk` was a shell alias, so the documented `sudo grow-disk` could never work; it is now a real `writeShellScriptBin` with a pinned PATH.
- **nixos-vm** — `rebuild_os_proxmox.sh` globbed `./result/` *before* the `--build` step, so a clean tree could never image; glob moved after the build.
- **nixos-vm** — `build_proxmox.sh` wrote the age private key world-readable (0644 on a default Proxmox host); added `umask 077` + explicit `chmod 600`.
- **nixos-vm** — `notify-failure@` passed the journal excerpt on curl's argv; now piped via `--data-binary @-`.
- **nixos-vm** — `10-lan.link` matched a MAC nothing has after a re-image; now matches both (see D-42).
- **nixos-vm** — `configuration.nix` 1061 → 131 lines across seven new `nixos/modules/*.nix`; proven system-identical bar the tmpfiles order (D-44).
- **nixos-vm** — dead `STACKS` variable and two stale comments removed from `backup-prepare.sh`.
- **vps** — fail2ban's `sshd`/`authentik` jails restated `maxretry`/`bantime` already set in `[DEFAULT]`, so raising the module-level value would have silently done nothing; duplicates removed.
- **vps** — `deploy.sh`: `trap` body broke on a whitespace `TMPDIR`; `chmod 600` moved before the age key is written.
- **desktop** — `hdmi-iec958-enable` was pulled in by `sleep.target` but not ordered `After=` it, so it could run before suspend rather than after resume; fixed.
- **desktop** — real workstation FQDNs and the Kerberos realm removed from `modules/home/work-vpn.nix` (see D-13 for the mirror history).
- **desktop** — `ssh-identities.nix` header claimed it derives `matchBlocks`; it derives `settings`, and following the stale text reintroduces a deprecation warning.
- **desktop** — `test.sh`'s statix and nixfmt gates were silently skipped on any machine without them installed (i.e. this one); now fetched from the flake's locked nixpkgs, plus a Home-Manager dry-run build.
- **desktop** — new `nixos-de/statix.toml` so statix is clean and actually gates (see D-47).
- **sops** — `deploy-check` was **red** at the start of the review (`sops-declared`: 4 drifts); now green.
- **sops** — `tests/fixtures/vps-rotated.sops.yaml` held 8 of 32 declared keys, so the `rotation` suite's specialisation could not have activated since the 2026-09-05 OIDC rollout; filled out.
- **sops** — `nixos-de/secrets.sops.yaml.example` was missing `ssh/gatech` and `ssh/forgejo`, both declared — a desktop rebuilt from the example would fail activation.
- **sops** — `tests/fixtures/vps.sops.yaml` was missing `FORGEJO_OIDC_CLIENT_SECRET`, which `modules/authentik.nix` declares — the `vps`/`authentik`/`rotation` suites would have failed sops-nix activation.
- **sops** — all 35 `.example` files regrouped and sorted (2,265 → ~1,000 lines), key sets unchanged and verified programmatically.
- **sops** — new `sops-gen sort` (decrypt → reorder to the example's key order → re-encrypt, with a permutation guard before the write and a decrypt-compare after).
- **sops** — dead `quote_for()` helper removed from `sops-gen`.
- **stacks-a** — `stacks/backrest/ssh_config`'s header told the operator to replace a `uXXXXXX` placeholder the file no longer has.
- **stacks-a** — `samba-init.sh` hardcoded "7 passwords present" while the count comes from the `USERS` list; now computed.
- **stacks-a** — `stacks/tracking/compose.yaml` interpolated three OIDC secrets as bare `${VAR}`, warning on every `docker compose` call; now `${VAR:-}`.
- **stacks-a** — documented *why* `scan-downloads.sh` must scan inside `.incomplete` (rename preserves mtime) — the exact "obvious cleanup" a future reviewer would make (see D-30).
- **stacks-a** — corrected a stale hazard claim in the samba stack: dropping `lo` from `SAMBA_INTERFACES` no longer breaks the healthcheck, because `config.yml` appends `bind interfaces only = no`.
- **stacks-b** — `stacks/util/glance.yml` violated its own stated coverage rule; added the four missing Caddy-routed services (`actual`, `wealthfolio`, `mealie`, `excalidraw`) and named `vlogs-ingest` as a deliberate omission.
- **stacks-b** — `beszel-init.sh` interpolated `BESZEL_SYSTEM_NAME` into `config.yml` with no charset check, while `TOKEN` in the same document had one; guard added.
- **stacks-b** — `windmill-init.sh`: dead `token = secret` alias removed, misleading `1. → 3. → 4.` step numbering fixed.
- **stacks-b** — `stacks/util/compose.yaml` claimed port 10406 was free; `stacks/excalidraw` has held it since 2026-09-01.
- **tests** — `update-images.sh` `light` tier silently **deleted** real pins, so a committed run passed `image-pins` and broke `checks.{authentik,paperless,backrest}` at eval; pins now carried over verbatim.
- **tests** — `update-images.sh` had no `trap`, so an interrupted run left `images.nix.tmp` in the tree — the exact artifact `tracked-artifacts` exists to catch.
- **tests** — `update-images.sh`: an empty scan would have wiped all 82 pins (`xargs` without `-r`, status swallowed by process substitution); added a hard refusal.
- **tests** — `update-images.sh` `HEAVY_RE` named none of the current multi-GB images, so `light` was no longer light; and `nix-prefetch-docker` was re-evaluated 82 times per run.
- **tests** — `renovate.json`'s `caddy-fork-tag` manager could never resolve an upgrade, and had it fired it would have rewritten the composite tag to a bare version, dropping the plugin half (see D-52).
- **tests** — `run.sh all` built the Proxmox image without `--print-build-logs`, so the only CI job that builds it could not show why it failed.
- **tests** — three copies of the Caddyfile handle-block parser in `lints.nix` collapsed to one shared `pyCaddyHandles`, semantics preserved exactly; all 24 lint build logs compared byte-for-byte.
- **tests** — `.forgejo/workflows/lints.yml` claimed `nixos/modules/forgejo-runner.nix` is "not yet imported anywhere" (it is, at `configuration.nix`), and `suites.yml` still named the retired Arcane deploy plane.
- **tests** — `heavy-nightly.yml` gained `workflow_dispatch` (see D-53); `tests/README.md` gained a 37-row suite table (24 suites previously had no description anywhere).
- **tests** — dead code removed: `sources.nix`'s `nixpkgsRev`, `profiles.nix`'s `dockerPin`.
- **security-apply** — the `backup-vps` key on the VPS is now `restrict`-prefixed (no pty, no forwarding, no user rc) — AS-3's SAFE-NOW half.
- **security-apply** — `deploy` gained a `deploy-last-ok` resume stamp (a retry after a mid-chain abort used to exit 0 having deployed nothing) and no longer swallows `stack-git-sync` / `decrypt-sops-envs` failures with `|| true` — AS-10.
- **security-apply** — `stacks/ntfy/server.yml`'s header now states the anonymous read-write risk as accepted rather than as "reaching it already requires being on the tailnet" — AS-2b.
- **security-apply** — `headscale-vps/policy.hujson` now warns that `tag:server:443` is Caddy and therefore fronts every vhost — AS-6's SAFE-NOW half.
- **security-apply** — **new `auth-coverage-required` lint** (`tests/lib/lints.nix`): every `handle @x` in `stacks/caddy/Caddyfile` must be forward-authed, present in an Authentik blueprint's `redirect_uris`, or carry a written `UNAUTHENTICATED_OK` reason — the AS-5 reverse leg. Green at 48 vhosts: 24 forward-authed, 17 OIDC, 8 exempt. Stale exemptions are an error in both directions, and two parser-rot sentinels (bentopdf must parse as protected, paperless as OIDC) stop a broken parser becoming a false green.
- **security-apply** — `./tests/run.sh deploy-check` now prints the exemptions still marked `TODO: decide`; two are seeded, `backrest` (D-04) and `ntfy` (D-02).
- **security-apply** — `komodo/compose.yaml`'s invariant-#1 paragraph now says the invariant keeps the *key* out, not the *plaintext*: Periphery runs as root and bind-mounts `/srv/stacks` read-write, so it holds every deployed secret — AS-8.
- **security-apply** — **behaviour change:** `deploy`'s remote leg now *fails* on a non-zero `stack-git-sync` or `decrypt-sops-envs` instead of swallowing both with `|| true`. Because `decrypt-sops-envs` exits 1 only on a newly-failing set, one broken `.sops.env` blocks the first deploy after it breaks and then lets later ones through (see D-22 if that is the wrong shape).
- **security-apply** — ACCEPTED notes added for the two argv exposures after verifying upstream has no file/env alternative: `stacks/forgejo/forgejo-init.sh` (`--secret`) and `stacks/notes-sync/compose.yaml` (`--gui-password`). Both are in Accepted risks above.
- **security-apply** — `sops-declared` extended: a `nixos-de` case (13 declared names derived from `nixos-de/ssh-identities.nix` and `modules/nixos/work-vpn.nix`, plus all 14 keys example-vs-real), `tests/fixtures/vps-rotated.sops.yaml` as a third parity file, and `nixos/{forgejo-runner,renovate}.sops.env` vs their examples. Output is now `3 hosts, 6 parity files, 2 dotenv pairs`.
- **security-apply** — `tests/suites/vps.nix` gained a `curl --path-as-is` traversal negative (`/api/v3/flows/executor/../instances/` must still hit the restricted matcher), locking in behaviour that was measured but untested.
- **security-apply** — stale cross-file pointers fixed: `tests/suites/services-vm.nix` (`configuration.nix` → `modules/secrets.nix`), `tests/suites/docspace.nix` (a `backup-prepare.sh:192` line number → the named `require_running docspace_db` block), `host-network-declared`'s gatus rationale (repointed off the trimmed ntfy header), and `deploy`'s header (`docs/deploy.md §5.6` → `deploy-handbook.md §18`).
- **declarative-apply** — Kavita's *Provision Accounts* is a repo fact: `stacks/books/books-init.sh`'s existing whole-DTO settings round trip now also sets `oidcConfig.provisionAccounts`, guarded so an upstream rename or the ready-and-OFF state skips it and `authority` is never touched.
- **declarative-apply** — BookStack admin now comes from an Authentik group on every login (`OIDC_USER_TO_GROUPS` + `OIDC_GROUPS_CLAIM` in `stacks/tracking/compose.yaml`), and re-asserts after a rebuilt MySQL volume.
- **security-apply** — the matching `authentik_core.group` (`id: group-admin`, `name: Admin`) is declared in `headscale-vps/authentik/blueprints/custom/headscale-oidc.yaml` ahead of the user entries, with idan's `groups:` referencing it via `!Find`. Verified against a real Authentik 2026.5.6 in the VM suite (`{"name":"Admin","is_superuser":false,"users":["idan"]}`). No property mapping was needed — the pinned tag's `profile` scope emits `groups` and `bookstack-oidc.yaml` already requests that scope. The `docs/for-shame.md` BookStack chore row is gone, replaced by a note describing the mechanism.
- **declarative-apply** — `stacks/vaultwarden/compose.yaml` states `SSO_SIGNUPS_ALLOWED=true` explicitly; the comment claiming "NOT auto-provision" was wrong and the `/admin` invite step was already redundant.
- **declarative-apply** — qBittorrent: `categories.json` is seeded beside `qBittorrent.conf`, so the `audiobooks` category exists on a fresh volume **with the tunnel down**; plus a drift guard shouting when the stored `WebUI\Password_PBKDF2` no longer matches `.env`.
- **declarative-apply** — `stacks/media/media-init.sh`'s Profilarr database check was a substring match on the whole serialised JSON, so any record mentioning `trash` hard-failed the entire init; now matched per record on `name`/`repository_url`/`url`.
- **declarative-apply** — `stacks/media/scan-downloads.sh` now prunes settle records whose entry has vanished; a stale one let a *later* torrent of the same basename look settled on its first pass and be promoted mid-download.
- **declarative-apply** — `stacks/tracking/tracking-init.sh` now sweeps leftover `tracking-init-*` Karakeep keys; a run of failed revokes previously accumulated live full-access API keys with nothing to clean them up.
- **declarative-apply** — new `stacks/beszel/beszel-role.sh` + a `beszel-role` oneshot promote the env-seeded app user to `admin` (PocketBase's `InitializeUserRole` defaults it to `user`); the suite caught the live bug.
- **declarative-apply** — the Grafana plugin image is built: new `stacks/logging/Dockerfile` and `.github/workflows/build-grafana-vlogs.yml` on the `stacks/caddy` pattern. The compose pin deliberately still points at stock Grafana — switching it is D-39.
- **declarative-apply** — **AS-9 applied**: the VictoriaLogs accepted-risk marker is back on `stacks/logging/compose.yaml`'s `ports:` block with the widened `/select/*` + `/insert/*` wording.
- **declarative-apply** — **AS-11 applied**: `karakeep_meilisearch` takes `MEILI_MASTER_KEY=${MEILI_MASTER_KEY:-}` instead of the whole tracking `.env` (BookStack's MySQL root password, `NEXTAUTH_SECRET`, `HBOX_AUTH_API_KEY_PEPPER` and three OIDC secrets).
- **declarative-apply** — `secrets-gen/manifest.yaml`: the header cite to the non-existent `SOPS-KEYGEN-PLAN.md` repointed at `ServerNotes/designs/sops-keygen.md`, and `books/AA_MIRROR_URLS` (D-60) plus `VPN_TYPE`/`VPN_PORT_FORWARDING` added as `config` targets. Key sets unchanged, so `stack-env-drift` stays green.
- **in progress** — `tests/suites/authentik.nix`'s rendered-`EnvironmentFile` subtest still asserts exact set equality against **7** variables while the template renders **29**; pre-existing drift, being fixed on this branch.
- **declarative-apply** — two **pre-existing red suites** fixed, both stale since the 2026-09-05 OIDC rollout: `vaultwarden` (the container would not start — `tests/fixtures/vaultwarden.sops.env` shipped an empty `SSO_CLIENT_SECRET` while `SSO_ENABLED=true` errors unconditionally on it; **production was never affected**, only the fixture had rotted) and `tracking` (the suite still asserted the pre-rollout OIDC-off contract while the compose had OIDC on; rewritten as "OIDC is ON, and local login survives where it must").
- **docs** — `LONGRUN-STACKS.md` and `nixos-de/AGENT_REVIEW_WORKFLOWS.md` deleted as point-in-time logs (see D-56 for what remains, all of it in ServerNotes).

**The one arch-security SAFE-NOW patch still unapplied** is AS-17's IoT-VLAN sentence in the `loopback-binding`
exemption text (`tests/lib/lints.nix`) — no lane owned that file's exemption table; it is listed under Accepted
risks. Everything else in the SAFE-NOW set landed (AS-2b, AS-3, AS-5, AS-6, AS-8, AS-9, AS-10, AS-11).
