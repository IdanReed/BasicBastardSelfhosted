# CLAUDE.md

Infrastructure for one homelab: one NixOS flake (three hosts), Docker Compose
stacks deployed by Komodo, secrets in SOPS + age. Start with `README.md`; the
runbooks are `docs/bring-up.md` (from nothing) and `docs/deploy.md` (day-2);
the service inventory is `docs/services.md`.

## Workflow

- Edit and commit in the working copy. Pushing is allowed, to any remote and
  any branch. Never force-push.
- The git root is **Forgejo**: `git push forgejo main`. GitHub is only a push
  mirror; Komodo never sees a push that lands only there.
- Pushing `main` to Forgejo **is a deploy** for `stacks/` and `komodo/sync/`:
  the webhook runs Komodo's `apply`, which deploys every stack whose files
  changed. Push `main` only with `./tests/run.sh` green.
- Host changes (`nixos/`, `headscale-vps/`, `forgejo/`, `komodo/` outside
  `komodo/sync/`, any `env*.nix`) and every secret go live with
  `nixos-rebuild switch` — `nrs-vm`, `nrs-vps`. **Switch before pushing a
  secret change**, or the stack redeploys with its old env.
- OIDC, forward auth and LDAP: `nrs-vps` first (the provider), then `nrs-vm`,
  then the push. VPS log shipping is the one reversed case.

## Commands

```bash
./tests/run.sh                 # structural lints, seconds — run constantly
./tests/run.sh deploy-check    # + sops readiness and operator to-dos
./tests/run.sh stack <name>    # one stack booted alone, the fast loop
./tests/run.sh <suite>         # a VM suite (see tests/README.md)
./tests/update-images.sh       # after changing any image tag
./nixos/generate-stack-dirs.sh # after adding /mnt paths to a stack
nrs-vm / nrs-vps / nrs / hms   # switch the VM / VPS / desktop / home (nixos-de/home.nix)
cd nixos-de && ./test.sh       # desktop config check without deploying
```

## Layout

| Path | What |
|---|---|
| `flake.nix` | `.#services-vm`, `.#headscale-vps`, `.#proxmox-image`, `.#desktop`, `homeConfigurations.idan`. Servers on the stable nixpkgs input, the desktop on unstable |
| `nixos/` | services VM: `configuration.nix` (imports, identity, packages) and one unit area per `modules/*.nix` — cite the file, not a line number |
| `headscale-vps/` | VPS: native headscale, Authentik from `authentik/compose.yaml` + `blueprints/custom/`, deployed only by `nrs-vps` |
| `stacks/<name>/` | one compose stack; registered by a `[[stack]]` block in `komodo/sync/stacks.toml` |
| `komodo/`, `forgejo/` | the deploy plane — host units, never stacks |
| `secrets/shared.sops.json` | values both servers read: OIDC client secrets, idan's password, the vlogs token, LDAP secrets |
| `secrets-gen/` | `sopsgen` (`apply`, `rotate`, `sort`, `view`) and `manifest.yaml` |
| `tests/` | offline NixOS VM suites + lints; not a flake, so untracked files test without `git add` |

## Secrets

- One age key; the private half lives only at
  `/var/lib/sops-nix/sops_age_key.txt` on each host — never copy it into the
  workspace. Decrypt inline:
  `SOPS_AGE_KEY="$(sudo cat /var/lib/sops-nix/sops_age_key.txt)" sops …`, or
  `sopsedit <file>`. Encrypting a new file needs only the public key:
  `sops -e -i <file>`.
- A value is stored **once**: `<host>/secrets.sops.yaml` (OS),
  `stacks/<name>/secrets.sops.json` (stack), `secrets/shared.sops.json` (both
  servers). A value built from others goes in `stacks/<name>/env.nix`
  (`secret "KEY"`, `shared "KEY"`), never as a second stored copy.
- sops-nix renders each stack's env; `stack-env-publish` copies it to
  `/run/stack-env/<name>.env` (0400, every value single-quoted). Compose reads
  it as `env_file:` and for `${VAR}` interpolation.
- Keep `secrets.example.env`, the real file and
  `tests/fixtures/stacks/<name>.sops.json` to one key set (`stack-env-drift`),
  and add a `secrets-gen/manifest.yaml` entry for every generated key.
  Fixtures are encrypted to the committed test key (`tests/keys/`).
- 🚨 Never regenerate a secrets file from its `.example` — sops has no
  append-without-decrypt, so that destroys real values. The ciphertext length
  tells a real value from a `changeme_` placeholder.
- 🚨 Never `ssh-keygen` into `/var/lib/backup/` on a host; SSH private keys are
  sops values, public halves live in `ssh-pubkeys.nix`, and `authorizedKeys`
  is generated from it.

## Stack conventions

- Ports: the next free one in the domain's 50-port block (`docs/services.md`).
  Publish on `127.0.0.1` only; Caddy (`stacks/caddy/Caddyfile`) is the way in,
  at `<name>.svc.idanreed.com`.
- Volumes absolute: `/mnt/fast/<service>/` for config and databases,
  `/mnt/slow/<purpose>/` for bulk.
- Images pinned to an explicit tag, then `./tests/update-images.sh`.
- Databases `container_name: <name>_db`, user `<name>` (the backup loop keys
  on it).
- A new stack also needs: a `[[stack]]` block (`tags = ["gitops"]`), its row in
  `docs/services.md`, a suite (`stackChecks` or `tests/suites/<name>.nix`),
  Gatus probes, and backup wiring — `docs/deploy.md` has the checklist.
- Authentik blueprints: provider names are unique across all provider types
  and slugs are unique; admin-only apps bind the `Admin` group.

## Writing docs and comments

Docs are steps and rules, not a log: no dated entries, no "was X, now Y", no
incident narratives — a rule learned the hard way is stated as a rule. Prefer
tables and short lists. This repo is mirrored publicly: no private notes,
personal data or attack-chain write-ups. Commit messages: imperative summary
of what and why; no co-author or tool trailers.
