# Deploy runbook

The actionable "how to deploy" doc for this fleet — commands, order, gotchas.
It lives in the code repo so it stays next to what it deploys.

**This is a runbook, not a design doc.** For *why* things are shaped this way,
cross-reference ServerNotes:

- Full from-scratch bring-up with per-step verification: `ServerNotes/designs/deploy-handbook.md`
- Day-2 operations (add stack, rotate secret, image update, backups): `ServerNotes/designs/maintenance-handbook.md`
- OIDC rollout runbook (the canonical stack-deploy ordering): `ServerNotes/designs/oidc-rollout.md`
- Service inventory + port table: `ServerNotes/designs/_overview.md`

All `stacks/*` paths are relative to the `BasicBastardSelfhosted` repo root.
Aliases (`nrs`, `nrs-vps`, `sopsgen`, `sopsedit`, `redeploy`) are defined in
`nixos-de/home.nix`; run `aliases` to list them.

---

## 1. The three deploy targets

Three independent flakes, three different deploy planes. **Always `cd` into the
target directory first** — they are not one workspace and each has its own lock.

| Target | Directory | Flake output | Deploy plane | One-line deploy |
|---|---|---|---|---|
| Services VM (Proxmox, `10.0.0.3`) | `nixos/` | `.#services-vm` | **Komodo** + host git-sync/decrypt units; OS via `nixos-rebuild --target-host` | OS: `nixos-rebuild switch --target-host idan@10.0.0.3 --use-remote-sudo --flake .#services-vm`  ·  stacks: `git push forgejo main` then `redeploy` |
| Headscale VPS (Hetzner) | `headscale-vps/` | `.#headscale-vps` | **`nixos-rebuild --target-host`** (no manager, no git checkout on host) | `nrs-vps` |
| Desktop | `nixos-de/` | `.#desktop` + `homeConfigurations.idan` | local `nixos-rebuild` / `home-manager` | `nrs` (system) · `hms` (home) |

Key distinction: **the services VM pulls stacks from git; the VPS does not.**
A VPS change needs `nrs-vps` (it reads the *local* flake and pushes over the
tailnet). A services-VM *stack* change needs a `git push forgejo main` +
redeploy. A services-VM *OS* change needs a `--target-host` rebuild.

Full provisioning detail (Proxmox image build, `nixos-anywhere`, Ventoy USB)
is in `deploy-handbook.md` §3, §5, §10.

---

## 2. Secrets first

One age key encrypts everything. The **private key lives only at
`/var/lib/sops-nix/sops_age_key.txt` (0700 root)** on every host including the
desktop — never in the workspace, so every decrypt costs a sudo. Two file
formats with different jobs:

- **OS-level secrets** — `*/secrets.sops.yaml` (**YAML**), decrypted per-key by
  sops-nix at activation into `/run/secrets/<name>`. Applied by a
  `nixos-rebuild switch`.
- **Application secrets** — `stacks/<name>/.sops.env` (**dotenv**), decrypted
  *on the host* by `decrypt-sops-envs` into a sibling `.env` read via `env_file`.
  Delivered to the services VM by git.

### The commands

```bash
# Edit an existing sops file in place (sudo-gated decrypt, edits in Zed)
sopsedit stacks/<name>/.sops.env
sopsedit nixos/secrets.sops.yaml            # or headscale-vps/, nixos-de/

# Generate + place all pending managed secrets (secrets-gen/manifest.yaml).
# Writes cross-host twins to the right files. One sudo for the age key.
sopsgen apply
sopsgen apply --dry-run                     # keyless, read-only preview
sopsgen rotate <app>/oidc                   # rotate one managed secret

# Encrypt a NEW plaintext file (pubkey-only — no age key, no sudo)
sops -e -i <file>
```

After a `sopsedit`, **check `git diff`** — if Zed's `--wait` returns instantly
against an already-running instance, sops re-encrypts the *unedited* tmpfile and
the edit is silently lost (the diff is the proof it took).

🚨 **Never "regenerate from the .example"** assuming a value is a placeholder.
sops has no append-without-decrypt, so that destroys real key material. Check
ciphertext length first: a real ed25519 key is ~400 bytes encrypted, a
`changeme_` placeholder ~40.

🚨 **Single-quote any value containing `$`** in a plaintext `.sops.env` before
encrypting (password hashes especially) — `docker compose` interpolates
`env_file` values, and `decrypt-sops-envs` sources nothing, so Compose is the
only expander (§6).

---

## 3. First-wave infra bring-up (from scratch)

Ordered dependency chain. Each step below is the *key command*; the full
procedure with per-step verification is `deploy-handbook.md` (section numbers
cross-referenced). `TAILSCALE_AUTH_KEY` stays `changeme` by design until step 4.

1. **Age key + repos** (`deploy-handbook.md` §1). Key at
   `BasicBastardSelfhosted/sops_age_key.txt`; the provisioning scripts deliver
   it to each host's `/var/lib/sops-nix/`. 🚨 Also write the **offline recovery
   artifact** (age key + restic password + Storage Box creds, off-infra) — the
   single largest unmitigated risk.

2. **DNS zone on Cloudflare** (`deploy-handbook.md` §2). Create the A records
   **before** the VPS deploy (ACME HTTP-01 fails otherwise), grey-clouded:
   - `headscale.idanreed.com` → VPS public IP
   - `auth.idanreed.com` → VPS public IP
   - `*.svc.idanreed.com` → services VM **tailnet** IP (added after §5)
   - `tailnet.idanreed.com` → **MUST NOT exist publicly** (MagicDNS only)

3. **Headscale VPS** (`deploy-handbook.md` §3). Fill
   `headscale-vps/secrets.sops.yaml` (7 keys). 🚨 Boot Hetzner **rescue mode**
   first (stock Ubuntu can't kexec the installer), then:
   ```bash
   ssh-add /run/secrets/ssh/vps          # deploy.sh uses BatchMode
   cd headscale-vps && ./deploy.sh <VPS_IP>   # DESTRUCTIVE: wipes + installs
   ```
   Run as yourself, not sudo. First `--target-host` rebuild may need one
   on-box build (trusted-users). Verify headscale + authentik + caddy are up.

4. **Mint tailnet keys** (`deploy-handbook.md` §4). On the VPS — the first user
   is a throwaway `bootstrap`, **NOT `idan`** (the real `idan` is created from
   OIDC in §8; naming the bootstrap user `idan` mints a duplicate on first OIDC
   login and the ambiguous `idan@` then locks the whole fleet out):
   ```bash
   sudo headscale users create bootstrap
   sudo headscale preauthkeys create -u <bootstrap-id> --reusable --expiration 24h
   ```
   `--reusable` is deliberate (autoconnect re-runs on a timer). Put the key into
   **both** hosts' secrets, then rebuild the VPS so it joins its own tailnet:
   ```bash
   sopseditnvim headscale-vps/secrets.sops.yaml   # TAILSCALE_AUTH_KEY
   sopseditnvim nixos/secrets.sops.yaml           # TAILSCALE_AUTH_KEY
   nrs-vps
   ```
   After the first OIDC login creates `idan` (§8 / §10.8), reconcile: move the
   bootstrap nodes onto it (`headscale nodes move -i <node> -u <idan-id>`) and
   rename/retire the bootstrap user. Bootstrap nodes have no tailnet *service*
   access until then — expected, since §5–§7 use SSH/LAN.

5. **Services VM + Komodo plane** (`deploy-handbook.md` §5). On the Proxmox host
   (data disks partitioned by hand first — see §5.1 there; `--cpu host` + static
   `ens18` are required):
   ```bash
   cd nixos
   ./rebuild_os_proxmox.sh 110 --build       # build image + reimport OS disk
   ./build_proxmox.sh 110                     # inject age key via cloud-init, start VM
   ```
   🚨 **Reboot once** after first boot (cloud-init writes the key after the first
   sops activation). Then the **required** first config-only rebuild (the image
   boots a reduced config without the `/srv` `/mnt` mounts):
   ```bash
   nixos-rebuild switch --target-host idan@10.0.0.3 --use-remote-sudo --flake .#services-vm
   ssh idan@10.0.0.3 'sudo systemctl restart docker'
   ```
   Then seed `/srv/komodo` (fill `komodo/.sops.env`, scp `compose.yaml` +
   `.sops.env` into `/srv/komodo/`) and `sudo systemctl start bootstrap-komodo`.
   Brings up Komodo Core (loopback :10000), Periphery, FerretDB, Postgres.

6. **Forgejo + the GitOps loop** (`deploy-handbook.md` §6). Chicken-and-egg:
   seed `/srv/stacks` once by hand, register + deploy the **forgejo** stack in
   Komodo, create the headless admin, register the two SSH pubkeys
   (`STACK_GIT_SSH_KEY` → repo deploy key **read-only**; `ssh/forgejo` → user SSH
   keys), create the `idan/BasicBastardSelfhosted` repo, add the `forgejo` remote,
   push `main`. **Deploy ntfy first** among the rest (every host unit's
   `OnFailure` posts to it). After this, `stack-git-sync` owns `/srv/stacks`.

7. **Caddy + Cloudflare TLS** (`deploy-handbook.md` §7). Needs the prebuilt
   `ghcr.io/idanreed/caddy-cloudflare` image, the CF `Zone:DNS:Edit` token, and
   the VM on the tailnet. Fill `stacks/caddy/.sops.env`
   (`TAILNET_IP=$(tailscale ip -4)`, `CLOUDFLARE_API_TOKEN`), push, create the
   `*.svc` A record at the **same** tailnet IP, register + deploy caddy. One
   DNS-01 wildcard cert for `*.svc.idanreed.com`.

8. **OIDC end to end** (`deploy-handbook.md` §8 + `oidc-rollout.md`). Headscale
   web login via Authentik, forward-auth pilot, native OIDC clients. See §5 below
   for the deploy ordering.

9. **Storage Box + Backrest** (`deploy-handbook.md` §9). Order the box, enable
   **snapshots** (the only host-compromise control), fill the storagebox SSH
   identity + `stacks/backrest/.sops.env` (`RESTIC_PASSWORD`,
   `BACKREST_ADMIN_PASSWORD_BCRYPT` = base64-of-bcrypt, `DEADMAN_URL`), deploy,
   run one snapshot, then **do one real restore into a scratch dir** (no test
   covers the restore path).

10. **Desktop joins the tailnet** (`deploy-handbook.md` §10). After install:
    ```bash
    sudo tailscale up --login-server=https://headscale.idanreed.com --accept-routes
    ```

**Readiness gate before any live deploy:** `./tests/run.sh deploy-check`
(structural lints + `sops-declared` + operator to-dos). `./tests/run.sh` alone
is the always-green structural gate.

---

## 4. The stack deploy loop (day-2, the common case)

This is the repeatable "repo change → live" loop for a services-VM stack. Full
detail: `maintenance-handbook.md` §1 (add) and §2.1 (rotate).

```bash
cd ~/local/projects/server/BasicBastardSelfhosted

# 1. Secrets (if changed) — edit in place, or generate/place managed ones
sopsedit stacks/<name>/.sops.env     # then: git diff  (verify the edit took)
#   or: sopsgen apply

# 2. Deliver to the services VM. Forgejo is the git root — NOT origin/github.
git push forgejo main

# 3. The host converges on its own within ~1 min each (both minutely timers):
#    - stack-git-sync  → materialises /srv/stacks/<name>/{compose.yaml,.sops.env}
#    - decrypt-sops-envs → writes the sibling .env (make-style, chown 1000)

# 4. Recreate the changed containers (STOP-GAP — see below):
redeploy <name>            # or: redeploy   (all stacks; only changed recreate)
```

### Why `redeploy` exists — STOP-GAP for Komodo issue #1120

**Komodo's deploy-on-sync is upstream-broken (issue #1120).** A `RunSync` only
*registers* resources; it does not recreate containers. So after a push,
`stack-git-sync` pulls the new compose to `/srv/stacks` but the running
containers keep the **old** config — compose / OIDC / image changes sit
un-applied. (This is exactly why the OIDC rollout showed no login button until a
manual recreate.)

`redeploy` (defined in `nixos-de/home.nix`) is the stop-gap: it SSHes to
`10.0.0.3` and runs `docker compose -p <name> up -d` for each named stack (all
of `/srv/stacks/*` if none given). `up -d` recreates **only** containers whose
compose/env/image config-hash changed, so a no-arg run deploys exactly the
changed stacks — the Komodo-equivalent. `idan` is in the VM's docker group, so
no sudo.

> ⚠ `redeploy` converges each stack to **repo state**: a stack hand-patched live
> on the host reverts to its `.sops.env` value. Name stacks explicitly to avoid
> touching those.
>
> 🗑 Delete `redeploy` once Komodo deploys on sync. The proper path is the
> Komodo webhook / UI `DeployStack` (`maintenance-handbook.md` §1.10).

**Secrets don't restart containers on their own.** After a `.sops.env` rotation,
`stack-git-sync` + `decrypt-sops-envs` converge the `.env` (≤~2 min), but the
container keeps the old env until a redeploy.

### The VPS is different — no push, no git

VPS changes (Authentik, headscale, caddy) do **not** go through Forgejo.
`nrs-vps` reads the **local** flake and deploys over the tailnet:

```bash
cd headscale-vps && nrs-vps      # or from anywhere: nrs-vps
```

For the VPS's Authentik compose, the "redeploy" *is* the `nrs-vps` rebuild — the
systemd unit re-runs `docker compose up -d --wait` against the new store path.

---

## 5. Cross-host OIDC secrets

Native-OIDC client secrets are **cross-host twins**: one generated value lives in
two sops files — the VPS blueprint side (`headscale-vps/secrets.sops.yaml`, read
by the Authentik blueprint via `!Env`) and the consuming stack side
(`stacks/<name>/.sops.env`). `sopsgen apply` writes both from
`secrets-gen/manifest.yaml`. **`client_id` is public** (the slug); only the
secret is a sops value.

**Deploy order is load-bearing: VPS FIRST, then stacks** — or an app turns OIDC
on with no provider behind it (a lockout, not a login page; BookStack especially).
The canonical sequence (`oidc-rollout.md`):

```bash
sopsgen apply              # place both twin halves
nrs-vps                    # 1st: Authentik providers/apps + worker env live
git push forgejo main      # 2nd: deliver the stack .sops.env
redeploy <stack…>          # recreate the OIDC-enabled containers
```

Rotate a client secret the same way: `sopsgen rotate <app>/oidc` → `nrs-vps` →
`git push forgejo main` → redeploy. A mismatch between the two copies 401s at
token exchange, silently, at login time. Full per-service manual steps (Kavita's
UI toggle, Bookstack cutover, Actual's DB flip, the OFF-in-repo exceptions) are
in `oidc-rollout.md`.

---

## 5.5 Fleet users (login tiers)

Users are **declarative** — defined once in `headscale-vps/authentik/blueprints/
custom/headscale-oidc.yaml` (`authentik_core.user`, in `headscale-users`) and
propagated everywhere else. See `ServerNotes/designs/login-tiers.md`. Adding a
person is: a blueprint entry + a `secrets-gen/manifest.yaml` `user/<name>`
`copy_only` twin (Authentik + Windmill + Samba) + a Samba `auth:`/share pair
(next uid) + its `personal/<name>` `DIR_NOTES`. No UI clicking.

**One password per user, one place.** Each `user/<name>` entry names the VPS
`<USER>_INITIAL_PASSWORD` as its `source: true` target — the single hand-set
value. Every other target is derived from it: plain copies for Authentik (`!Env`,
re-asserted each apply), Windmill, and Samba. **idan is special:** his one
password is also the admin for the second-login services that can't federate —
Beszel (plain), Backrest (**bcrypt**), qBittorrent (**pbkdf2**) — so the former
separate `services-admin` password is gone. Edit idan's value once and every one
of those follows, hashes included.

**To set or change a password:**
```bash
sopsedit headscale-vps/secrets.sops.yaml   # type the memorable <USER>_INITIAL_PASSWORD
sopsgen rotate user/<name>                 # re-reads the source, re-derives EVERY
                                           #   copy + hash from it (idan → also
                                           #   beszel/backrest/qbit). No `apply`,
                                           #   no "blank the old value" dance.
```
`rotate` (not `apply`) is the tool for a change: `apply` only fills missing/
`changeme` targets and will refuse on "diverged twins" once a value differs.
`rotate` reads the `source:` target authoritatively and rewrites the rest.

**One-time migration** (Beszel/Backrest/qBit still hold the old generated
`services-admin` value, and Windmill has no idan key yet):
```bash
sopsgen rotate user/idan     # converges beszel/backrest/qbit onto idan's password
                             #   + adds IDAN_INITIAL_PASSWORD to windmill/.sops.env
```
This clears the `stack-env-drift` red on `windmill` (real `.sops.env` missing
`IDAN_INITIAL_PASSWORD` until `rotate` writes it).

**Then deliver it:**
```bash
nrs-vps                      # Authentik users + passwords live
git push forgejo main        # deliver windmill/samba/beszel/backrest/media to the VM
#   then in Komodo redeploy: windmill, samba, beszel, backrest, media
nixos-rebuild switch --target-host idan@10.0.0.3 --sudo --flake ./nixos#services-vm
#   ^ REQUIRED for Samba: creates the /mnt/slow/samba/personal/<name> tmpfiles
#     dirs (<uid>:1000 0700) — samba-init refuses to start until they exist.
#   ⚠ the services-VM flake is in ./nixos (its own flake), so `--flake ./nixos#…`
#     from the repo root, or `cd nixos` first. `--sudo` (was --use-remote-sudo).
```
Note: on an already-running Windmill, idan's account keeps its existing password
(a `users/create` is a no-op for an existing user) — a fresh `windmill_data`
picks up `IDAN_INITIAL_PASSWORD`, or reset it in the UI. The friends are created
with theirs on first run either way.

Each friend then enrols a device on the tailnet themselves
(`tailscale up --login-server=https://headscale.idanreed.com`, log in via
Authentik) — that's their action, not yours.

## 5.6 VPS log shipping (fail2ban / login-attempt dashboard)

The headscale VPS ships its journal to the services VM's VictoriaLogs, which is
what puts fail2ban bans and Authentik `login_failed` events on a Grafana
dashboard instead of behind an SSH session. Three pieces:
`headscale-vps/modules/log-shipper.nix` (native Alloy on the VPS), the
`vlogs-ingest.svc.idanreed.com` vhost in `stacks/caddy/Caddyfile`, and the
provisioned dashboard in `stacks/logging/dashboards/`.

🚨 **THIS IS THE ONE CHANGE `./deploy` SEQUENCES BACKWARDS.** §4's chain runs
`nrs-vps` *before* the services-VM stacks, which is right for OIDC (the app
redirects to a provider that must already exist) and wrong here for the mirror
reason: bringing up the shipper first points Alloy at a vhost that does not
exist yet. Naming stacks does **not** suppress it — the VPS leg fires off the
pushed diff, and this change touches `headscale-vps/`.

Nothing is lost when it happens (Alloy retries into its WAL, and the vhost
sitting idle the other way round is inert), but you will spend the time
debugging a 401 you created. Push first, so `deploy`'s VPS auto-detect stays
quiet, then take the two halves in order:

```bash
sopsgen apply                 # draws ONE VLOGS_INGEST_TOKEN into BOTH sides:
                              #   stacks/caddy/.sops.env + headscale-vps/secrets.sops.yaml
git add -A && git commit      # deploy refuses an uncommitted tree
git push forgejo main         # push HERE, not via deploy: with forgejo already at
                              #   HEAD, deploy's CHANGED set is empty and its
                              #   nrs-vps leg does not fire
./deploy caddy logging        # sync + decrypt + redeploy, stacks only
nrs-vps                       # LAST: brings up alloy against a vhost that now exists
```

**Verify (takes about a minute for the first push to land):**
```bash
# on the services VM — the freshness query the gatus probe runs
curl -s 'http://127.0.0.1:10456/select/logsql/query?query=_time:15m%20%7Bhost=%22headscale-vps%22%7D&limit=5'
# on the VPS — did the collector read anything at all?
curl -s http://127.0.0.1:12345/metrics | grep loki_source_journal_target_lines_total
journalctl -u alloy -n 50     # a 401 here means the two token halves disagree
```
Then open Grafana → **Login attempts & bans (VPS)**. If every panel is empty
but *VPS lines shipped* is non-zero, the shipping is fine and the panel queries
need adjusting; if *VPS lines shipped* is zero, nothing else on the page means
anything.

⚠ **The dashboard needs the datasource plugin**, which is still the one-time
operator install into `/mnt/fast/grafana/plugins` documented in
`stacks/logging/compose.yaml`. Until it lands, Grafana is healthy, the
dashboard exists, and every panel fails to query — use vmui on 10456 meanwhile.

🚨 **`sopsgen apply` is REQUIRED, not just recommended, and it gates the VPS
rebuild rather than only the log flow.** `modules/log-shipper.nix` *declares*
`sops.secrets.VLOGS_INGEST_TOKEN`, and sops-nix resolves every declared secret
at activation — so a `nrs-vps` against a `headscale-vps/secrets.sops.yaml` that
does not yet contain that key **fails the rebuild**, it does not merely ship no
logs. Loud rather than silent, which is the right way round, but it means the
first `./deploy` after this lands will stop at its VPS leg if the token was
never drawn.

Until `sopsgen apply`, `./tests/run.sh` also shows `stack-env-drift` on caddy
(`VLOGS_INGEST_TOKEN` pending in the real `.sops.env`) — expected, and the only
red in the gate; it clears with the same command.

## 6. Gotchas

- **The git-remote trap.** `git push forgejo main` — **not** `origin`/GitHub.
  `stack-git-sync` pulls from Forgejo over loopback; a push to `origin` never
  reaches the services VM, so the stack silently never updates. (GitHub is only a
  push mirror.)

- **The `.env` decrypt race.** A deploy can win a race against the first decrypt
  (the `.env` not yet written). Every stack's `env_file` **must** use the long
  form so a missing `.env` doesn't abort the whole stack:
  ```yaml
  env_file:
    - path: .env
      required: false
  ```
  This is `docker compose`'s own contract, honoured under either deploy plane.

- **Single-quote `$` in `.sops.env` values.** `docker compose` interpolates
  `env_file` values and `decrypt-sops-envs` sources nothing, so a bare or
  double-quoted `$` (password hashes) gets mangled. Single-quote before
  encrypting.

- **Init one-shot stuck `Created` after deploy.** A `restart: "no"` init
  container can be created before its dependency is healthy (seen on
  `docspace_init`, `excalidraw_api`). Recovery: `docker start <name>` or just
  redeploy — the long-running services carry `restart: unless-stopped`. But an
  init that **exits non-zero** (e.g. `samba-init`) is a real failure, usually a
  `changeme` `.sops.env` value — fix the secret, don't restart.
  (`maintenance-handbook.md` §7.1.)

- **New stack with `/mnt` ownership needs one OS rebuild before first deploy.**
  The generated tmpfiles rules land only at the next `nixos-rebuild switch`;
  until then docker creates bind sources root:root and a uid-1000 container
  breaks. Run `generate-stack-dirs.sh`, then the services-VM switch.
  (`maintenance-handbook.md` §1.5.)

- **Never `ssh-keygen` into `/var/lib/backup/` on a host** — sops-nix / tmpfiles
  re-own those keys on the next boot or switch and silently overwrite a
  hand-made one.
