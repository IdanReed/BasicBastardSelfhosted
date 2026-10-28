# Deploy — day-2 quick reference

Shipping a change to a fleet that already exists. Building it from nothing is
`ServerNotes/designs/deploy-handbook.md`; day-2 *procedures* (add a stack,
rotate a secret, image updates, restore drill, troubleshooting) are
`ServerNotes/designs/maintenance-handbook.md`.

Paths are relative to the repo root. `nrs`, `nrs-vm`, `nrs-vps` and `hms` are
shell aliases (`aliases` lists them); `sopsedit`, `sopseditnvim` and `sopsgen`
are zsh functions — both live in `nixos-de/home.nix`.

---

## The flow

```bash
# edit, then:
git add -A && git commit
nrs-vps            # only if headscale-vps/ or a value it reads changed
nrs-vm             # only if nixos/, forgejo/, komodo/ (not komodo/sync/), a stacks/*/env.nix
                   #   or a secret changed
git push forgejo main
```

An `env.nix`-only change (or `env.<part>.nix`) is the one the push does not
deploy (neither is a `config_files` entry): after `nrs-vm`, Deploy that stack in
the Komodo UI.

**Push is the deploy for stacks.** Forgejo's push webhook runs Komodo's `apply`
procedure: it re-applies `komodo/sync/` (registering, updating or removing
stacks), then deploys every stack whose files changed since its last deploy.
Nothing on the host signals Komodo, and there is no deploy script.

**Switch before you push when a secret changed.** A stack's environment is
rendered on the host by `nixos-rebuild switch`; the push only tells Komodo the
encrypted file changed. Pushed first, the stack redeploys with the *old* env,
and the later switch does not trigger another deploy — fix that with Redeploy on
the stack in Komodo's UI.

| Target | Flake output | How a change reaches it |
|---|---|---|
| Services VM (Proxmox, `10.0.0.3`) | `.#services-vm` | OS, Komodo, Forgejo and every stack env: `nrs-vm`. Stacks: `git push forgejo main` |
| Headscale VPS (Hetzner) | `.#headscale-vps` | `nrs-vps` — reads the **local** flake, no git, no checkout on the host |
| Desktop | `.#desktop`, `homeConfigurations.idan` | `nrs` (system) · `hms` (home) |

One flake at the repo root builds all three; the desktop's modules live in
`nixos-de/`.

---

## How a stack deploys

- `komodo/sync/stacks.toml` declares every stack: a Komodo **git stack** that
  Periphery clones from `forgejo:3000` into `/srv/komodo/stacks/<name>` and runs
  `compose.yaml` in `stacks/<name>`. The `komodo-sync-coverage` lint holds every
  block to the same shape and every `stacks/<name>` to a block.
- `komodo/fleet.toml` defines the `fleet` sync and the `apply` procedure:
  `RunSync fleet`, then `BatchDeployStackIfChanged "*"`. The host owns both —
  `komodo-sync-bootstrap` creates them and re-applies the file on `nrs-vm` —
  because `apply` runs the sync, and a sync that declared either one would have
  to update a resource that is busy running. A stack whose compose, `secrets.sops.json`
  or (for an app reading it) `secrets/shared.sops.json` changed is redeployed;
  `docker compose up -d` then recreates only the containers whose config or
  environment changed.
- Every repo file a service bind-mounts (a Caddyfile, an init script, a
  template) is a `config_files` entry with `requires = "Restart"` for the
  services that mount it — the `komodo-sync-coverage` lint derives the list
  from `compose.yaml` and prints any missing line. A push that changes only
  such a file restarts its consumers, which re-binds the new file. One push
  that changes both `compose.yaml` and such a file deploys only the services
  whose definition changed: restart the file's consumers from the UI.
- **Removing a stack's block destroys it** (`compose down`) and unregisters it —
  the sync runs in delete mode, scoped by `match_tags = ["gitops"]`: every block
  in `komodo/sync/` carries the tag, and nothing untagged is ever touched (Core's
  own `Local` server and system procedures, the sync, `apply`, anything made in
  the UI). A block without the tag is silently ignored — the lint refuses one.
- Komodo and Forgejo themselves are **not** stacks: Komodo deploys from Forgejo,
  so neither could bring the other up. Both run from the flake on `nrs-vm`
  (`bootstrap-komodo.service`, `forgejo.service`).
- To redeploy by hand: Komodo UI → the stack → Deploy.

---

## Secrets

One age key encrypts everything; the private key lives only at
`/var/lib/sops-nix/sops_age_key.txt` (0700 root) on every host, so every decrypt
costs a sudo. A value is stored **once**:

| File | Holds | Read by |
|---|---|---|
| `stacks/<name>/secrets.sops.json` | that stack's stored values | the services VM, rendering the stack's env |
| `stacks/<name>/env.nix` | values BUILT from others: a URL around a password, an OIDC secret from the shared file | the same render |
| `secrets/shared.sops.json` | OIDC client secrets, login passwords, the vlogs token | both hosts (`secrets/shared.nix`) |
| `*/secrets.sops.yaml` | OS secrets (SSH keys, tailscale, CI tokens) | sops-nix on that host |

On a switch, sops-nix renders each stack's env (`nixos/modules/stack-env.nix`)
and `stack-env-publish` copies it to `/run/stack-env/<name>.env`, root-only.
Compose reads it twice: `env_file:` for the containers, and `--env-file` (Komodo's
`additional_env_files`) for `${VAR}` interpolation in `compose.yaml`. Every value
is rendered single-quoted, so a `$` in a password or hash survives compose.

```bash
sopsedit <file>                # decrypt -> Zed -> re-encrypt in place
sopseditnvim <file>            # same in nvim; no --wait race
sopsgen apply                  # fill every missing managed secret
sopsgen apply --dry-run        # keyless, read-only preview
sopsgen rotate <name>          # change one managed value and re-derive its hashes
sopsgen view <file>            # print decrypted values
```

After a `sopsedit`, **check `git diff`.** If Zed's `--wait` returns instantly
against an already-running instance, sops re-encrypts the *unedited* tmpfile and
the edit is silently lost; the diff is the proof it took.

**Never regenerate a secrets file from its template** on the assumption a value
is a placeholder. sops has no append-without-decrypt, so that destroys real key
material. Check ciphertext length first — the base64 `data:` blob gives the exact
plaintext byte count (a real ed25519 key is ~400 bytes encrypted, a `changeme_`
placeholder ~40).

A new stack secret is a key in `secrets.sops.json` and its
`secrets.example.env` (the `stack-env-drift` lint pins the two and the test
fixture together). A value another secret already holds goes in `env.nix`,
never as a second stored copy.

🚨 **`sopsgen rotate user/idan` rewrites the secrets; it does not change five of
the seven logins.** qBittorrent (`qBittorrent.conf`), Backrest (`config.json`),
Beszel (`data.db`), Windmill (the account row) and **Jellyfin** all seed their
credential **once** and keep the old value. Each needs the seed file or volume
reset and the stack redeployed — for qBittorrent, stop the container, delete the
conf, then redeploy media. Only `qbit-init` warns about the drift; Backrest,
Beszel and Windmill are silent, and **Jellyfin is worse than silent — the next
deploy fails**, because `jellyfin-init` authenticates with the rotated value
against a server that still stores the old one. Reset it in the Jellyfin UI
first. Authentik and Samba do follow the rotation. Handbook §15 has the table.

---

## The two ordering traps

**OIDC and forward auth: VPS first.** An app that turns OIDC on before its
Authentik provider exists is a lockout, not a login page (BookStack especially —
`AUTH_METHOD=oidc` removes the local form). The client secret is one value in
`secrets/shared.sops.json`, so the order is about the provider existing, not
about copies matching:

```bash
sopsgen apply            # or: sopsgen rotate <app>/oidc
git add -A && git commit
nrs-vps                  # the provider
nrs-vm                   # the app's env
git push forgejo main    # the app
```

**VPS log shipping: VPS last.** Alloy on the VPS pushes *to* the
`vlogs-ingest.svc.idanreed.com` vhost, so that vhost must exist first:

```bash
sopsgen apply            # VLOGS_INGEST_TOKEN into secrets/shared.sops.json
git add -A && git commit
nrs-vm && git push forgejo main   # caddy + logging
nrs-vps                           # LAST
```

`headscale-vps/modules/log-shipper.nix` *declares* `sops.secrets.VLOGS_INGEST_TOKEN`,
so a VPS rebuild without that key **fails the rebuild** rather than silently
shipping nothing.

---

## Gotchas

- **The git-remote trap.** `git push forgejo main` — not `origin`/GitHub.
  Komodo clones from Forgejo; a push that lands only on GitHub (a push mirror)
  deploys nothing.

- **A secret changed but nothing redeployed:** the push came before the switch,
  or the change touched a value the stack's `config_files` do not track. Switch,
  then Redeploy the stack in Komodo.

- **Init one-shot stuck `Created`** is a deploy race — `docker start <name>`, or
  redeploy. An init that **exits non-zero** (`samba-init`) is a real failure,
  usually a `changeme` value: fix the secret, do not restart.

- **A new stack owning `/mnt` paths needs one OS rebuild first.** The generated
  tmpfiles rules land only at the next switch; until then docker creates bind
  sources root:root and a uid-1000 container breaks. Run
  `./nixos/generate-stack-dirs.sh`, then `nrs-vm`, then push.

- **Never `ssh-keygen` into `/var/lib/backup/` on a host.** sops-nix and tmpfiles
  re-own those keys on the next boot or switch and silently overwrite a hand-made
  one.

- **Readiness gate.** `./tests/run.sh` is the always-green structural gate;
  `SERVER_NOTES=../ServerNotes ./tests/run.sh deploy-check` adds `sops-declared`
  and the operator to-do report. Run the second before any live deploy.
