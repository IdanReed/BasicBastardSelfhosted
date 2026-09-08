# Deploy — day-2 quick reference

Shipping a change to a fleet that already exists. Building it from nothing is
`ServerNotes/designs/deploy-handbook.md`; day-2 *procedures* (add a stack,
rotate a secret, image updates, restore drill, troubleshooting) are
`ServerNotes/designs/maintenance-handbook.md`.

Paths are relative to the repo root. `nrs`, `nrs-vps` and `deploy` are shell
aliases (`aliases` lists them); `sopsedit`, `sopseditnvim`, `sopsgen` and
`redeploy` are zsh functions — both live in `nixos-de/home.nix`.

---

## The three deploy targets

Three independent flakes, three deploy planes. **`cd` into the target first** —
they are not one workspace and each has its own lock.

| Target | Directory | Flake output | How a change reaches it |
|---|---|---|---|
| Services VM (Proxmox, `10.0.0.3`) | `nixos/` | `.#services-vm` | OS: `nixos-rebuild --target-host`. Stacks: git push to Forgejo → `stack-git-sync` → redeploy |
| Headscale VPS (Hetzner) | `headscale-vps/` | `.#headscale-vps` | `nrs-vps` — reads the **local** flake, no git, no checkout on the host |
| Desktop | `nixos-de/` | `.#desktop`, `homeConfigurations.idan` | `nrs` (system) · `hms` (home) |

The key distinction: **the services VM pulls stacks from git; the VPS does not.**

---

## `./deploy` — the one command

```bash
sopsedit <file>                # or sopsgen apply / sopsgen rotate <name>
git add -A && git commit       # ./deploy refuses an uncommitted tree
./deploy [stack…]
```

One invocation: **gate** on an uncommitted tree (this is what catches the
untracked `.sops.env` that `sopsgen apply` leaves behind) → **push** `main` to the
`forgejo` remote → **VPS leg** (`nixos-rebuild … --use-remote-sudo`) if the pushed
diff touched `headscale-vps/` → **services-VM OS leg** if it touched `nixos/`,
deliberately *before* the stacks because a `nixos/` change often alters the very
units the stack leg drives → **stack leg**, force-starting `stack-git-sync` and
`decrypt-sops-envs` rather than waiting for their minutely timers, then
`docker compose -p <name> up -d` → **verify** every container is `running` or an
init that `exited 0`.

Stacks are auto-detected from the pushed diff. Naming them explicitly overrides
that but does **not** suppress the VPS leg — that fires off the diff. `--vps` and
`--vm` force either rebuild leg when auto-detect did not.

**`redeploy [stack…]`** is the no-push escape hatch: SSH to `10.0.0.3` and
`docker compose up -d` the named stacks (all of `/srv/stacks/*` if none given).
`up -d` recreates only containers whose config hash changed. It converges each
stack to **repo state**, so a stack hand-patched live on the host reverts —
name stacks explicitly. Komodo does not deploy on sync (upstream issue #1120),
which is why an explicit recreate exists at all.

If a rebuild leg fails, `./deploy` aborts *after* pushing. The retry is covered:
the script records the ref of the last **completed** run in
`<git-dir>/deploy-last-ok` and, when Forgejo is already at HEAD, diffs from that
stamp instead of computing an empty change set. Naming the stacks explicitly
still works as a manual override.

---

## Secrets

One age key encrypts everything; the private key lives only at
`/var/lib/sops-nix/sops_age_key.txt` (0700 root) on every host, so every decrypt
costs a sudo. `*/secrets.sops.yaml` (**YAML**) holds OS secrets, extracted per key
by sops-nix into `/run/secrets/<name>` at a `nixos-rebuild switch`;
`stacks/<name>/.sops.env` (**dotenv**) holds application secrets, delivered by git
and decrypted on the host into a sibling `.env` read through `env_file`.

```bash
sopsedit <file>                # decrypt -> Zed -> re-encrypt in place
sopseditnvim <file>            # same in nvim; no --wait race
sopsgen apply                  # fill every missing managed secret (twins included)
sopsgen apply --dry-run        # keyless, read-only preview
sopsgen rotate <name>          # change one managed value and re-derive its copies/hashes
sopsgen sort                   # normalise key order to the .example files
sopsgen view <file>            # print decrypted values
sops -e -i <file>              # encrypt a NEW plaintext file (public key only, no sudo)
```

After a `sopsedit`, **check `git diff`.** If Zed's `--wait` returns instantly
against an already-running instance, sops re-encrypts the *unedited* tmpfile and
the edit is silently lost; the diff is the proof it took.

**Never regenerate a secrets file from its `.example`** on the assumption a value
is a placeholder. sops has no append-without-decrypt, so that destroys real key
material. Check ciphertext length first — the base64 `data:` blob gives the exact
plaintext byte count (a real ed25519 key is ~400 bytes encrypted, a `changeme_`
placeholder ~40).

**Single-quote any value containing `$`** in a plaintext `.sops.env` before
encrypting (password hashes especially). `docker compose` interpolates `env_file`
values and `decrypt-sops-envs` sources nothing, so Compose is the only expander.

🚨 **`sopsgen rotate user/idan` rewrites the secrets; it does not change five of
the seven logins.** qBittorrent (`qBittorrent.conf`), Backrest (`config.json`),
Beszel (`data.db`), Windmill (the account row) and **Jellyfin** all seed their
credential **once** and keep the old value. Each needs the seed file or volume
reset and the stack redeployed — for qBittorrent, stop the container, delete the
conf, then `./deploy media`. Only `qbit-init` warns about the drift; Backrest,
Beszel and Windmill are silent, and **Jellyfin is worse than silent — the next
deploy fails**, because `jellyfin-init` authenticates with the rotated value
against a server that still stores the old one. Reset it in the Jellyfin UI
first. Authentik and Samba do follow the rotation. Handbook §15 has the table.

---

## The two ordering traps

**OIDC and forward auth: VPS first.** An app that turns OIDC on before its
Authentik provider exists is a lockout, not a login page (BookStack especially —
`AUTH_METHOD=oidc` removes the local form). `./deploy` already sequences it this
way. Rotating a client secret is the same order; a mismatch between the two twin
copies 401s at token exchange, silently, at login time.

```bash
sopsgen apply            # or: sopsgen rotate <app>/oidc
git add -A && git commit
./deploy                 # VPS leg, then the stacks
```

**VPS log shipping: VPS last.** Alloy on the VPS pushes *to* the
`vlogs-ingest.svc.idanreed.com` vhost, so that vhost must exist first. Push by
hand so `./deploy` has an empty diff and its VPS leg stays quiet:

```bash
sopsgen apply                 # one VLOGS_INGEST_TOKEN into caddy + the VPS file
git add -A && git commit
git push forgejo main
./deploy caddy logging        # stacks only
nrs-vps                       # LAST
```

`headscale-vps/modules/log-shipper.nix` *declares* `sops.secrets.VLOGS_INGEST_TOKEN`,
so a VPS rebuild without that key **fails the rebuild** rather than silently
shipping nothing.

---

## Gotchas

- **The git-remote trap.** `git push forgejo main` — not `origin`/GitHub.
  `stack-git-sync` pulls from Forgejo over loopback SSH; a push to `origin` never
  reaches the services VM and the stack silently never updates. GitHub is only a
  push mirror.

- **Secrets do not restart containers.** After a `.sops.env` change the sync and
  decrypt timers converge the `.env` within ~2 min, but the container keeps the
  old environment until something recreates it.

- **The `.env` decrypt race.** A deploy can beat the first decrypt. Every stack's
  `env_file` must use the long form so a missing `.env` does not abort the stack:

  ```yaml
  env_file:
    - path: .env
      required: false
  ```

- **Init one-shot stuck `Created`** is a deploy race — `docker start <name>`, or
  redeploy. An init that **exits non-zero** (`samba-init`) is a real failure,
  usually a `changeme` value: fix the secret, do not restart.

- **A new stack owning `/mnt` paths needs one OS rebuild first.** The generated
  tmpfiles rules land only at the next switch; until then docker creates bind
  sources root:root and a uid-1000 container breaks. Run
  `./nixos/generate-stack-dirs.sh`, then `./deploy --vm`. Related: any container
  running as a uid other than 1000 that bind-mounts a repo config file needs it
  0644, which `stack-git-sync` handles for delivered non-secret files.

- **Never `ssh-keygen` into `/var/lib/backup/` on a host.** sops-nix and tmpfiles
  re-own those keys on the next boot or switch and silently overwrite a hand-made
  one.

- **Readiness gate.** `./tests/run.sh` is the always-green structural gate;
  `SERVER_NOTES=../ServerNotes ./tests/run.sh deploy-check` adds `sops-declared`
  and the operator to-do report. Run the second before any live deploy.
