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

4. **Mint tailnet keys** (`deploy-handbook.md` §4). On the VPS:
   ```bash
   sudo headscale users create idan
   sudo headscale preauthkeys create --user 1 --reusable --expiration 24h
   ```
   `--reusable` is deliberate (autoconnect re-runs on a timer). Put the key into
   **both** hosts' secrets, then rebuild the VPS so it joins its own tailnet:
   ```bash
   sopsedit headscale-vps/secrets.sops.yaml   # TAILSCALE_AUTH_KEY
   sopsedit nixos/secrets.sops.yaml           # TAILSCALE_AUTH_KEY
   nrs-vps
   ```

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

**Passwords are hand-set + managed.** Each user's password is one memorable
value used for Authentik (tier-1 apps), Windmill, and Samba. In Authentik it is
re-asserted on every apply (a user's own change reverts on the next `nrs-vps`).

**The finish (after any user/password change):**
```bash
sopsedit headscale-vps/secrets.sops.yaml     # set <USER>_INITIAL_PASSWORD (memorable)
#   ⚠ when (re)setting idan: also blank the OLD SAMBA_IDAN_PASSWORD so the copy
#     propagates the new value, not the stale one. New users start empty (clean).
sopsgen apply                 # copy_only fans each value → windmill + samba
sopsgen rotate services-admin # ONE shared 2a admin password (idan) for
                              #   beszel/backrest/qbit — `apply` won't touch it
                              #   (targets already hold old values), only rotate
nrs-vps                       # Authentik users + passwords live
git push forgejo main         # deliver windmill/samba/etc. to the services VM
#   then in Komodo redeploy: windmill, samba, beszel, backrest, media
nixos-rebuild switch --target-host idan@10.0.0.3 --sudo --flake ./nixos#services-vm
#   ^ REQUIRED for Samba: creates the /mnt/slow/samba/personal/<name> tmpfiles
#     dirs (<uid>:1000 0700) — samba-init refuses to start until they exist.
#   ⚠ the services-VM flake is in ./nixos (its own flake), so `--flake ./nixos#…`
#     from the repo root, or `cd nixos` first. `--sudo` (was --use-remote-sudo).
```
Until `sopsgen apply`, `./tests/run.sh` shows `stack-env-drift` on windmill +
samba (the new keys pending in the real `.sops.env`) — expected, cleared by it.

Each friend then enrols a device on the tailnet themselves
(`tailscale up --login-server=https://headscale.idanreed.com`, log in via
Authentik) — that's their action, not yours.

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
