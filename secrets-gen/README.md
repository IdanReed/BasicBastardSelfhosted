# secrets-gen

`sops-gen` + `manifest.yaml`: generate-if-absent secret management over sops.
Fills the generate-class inventory (SOPS-KEYGEN-PLAN.md §3), refuses the
pull-class one (§7), and never overwrites real committed key material.

```bash
nix-shell secrets-gen/shell.nix          # sops, age, openssl, yq, wg, htpasswd, argon2, xxd
secrets-gen/sops-gen apply --dry-run     # read-only plan: plaintext key grep, no decryption
SOPS_AGE_KEY="$(sudo cat /var/lib/sops-nix/sops_age_key.txt)" secrets-gen/sops-gen apply
```

## Subcommands

| Command | Needs key | Does |
| --- | --- | --- |
| `apply --dry-run` | no | plan only — no writes, no decryption |
| `apply` | for full run | fill absent/`^changeme` values; create missing `.sops.env` from `.sops.env.example` (pubkey-only) |
| `rotate NAME [--force]` | yes | force-regenerate one entry (`--force` for frozen) |
| `list` | no | every entry: class, recipe, flags, present/missing per target |
| `view FILE` | for values | one file's keys + classes; values decrypted when possible |
| `search --keys PAT` | no | grep key names across all managed files |
| `search --values PAT` | yes | decrypt-and-grep values |

## Safety model

- **Fire condition**: a value is written only if the key is *absent* or its
  *decrypted* value matches `^changeme`. Never length heuristics. Re-runs are
  no-ops; random values never churn.
- **`--rotate` is the only way past a real value**; `freeze: true` entries
  (RESTIC_PASSWORD, ACCESS_TOKEN_SALT, firefly APP_KEY, …) additionally
  refuse rotate without `--force`.
- **pull-class hard-refuses generation** — a fabricated TAILSCALE_AUTH_KEY
  would pass the `changeme_*` deploy guard and 401 silently later. They are
  reported as "missing, add by hand" with the how-to note.
- **Twins** (same-file pairs, URL-embedded passwords, cross-host OIDC): one
  draw per entry, rendered into every target in one pass. If one side is
  already real, that value is *propagated*, never redrawn; `copy_only`
  entries (immich OIDC) never fresh-draw at all.
- All writes go through `sops set --value-stdin` / `sops encrypt` — recipient
  from `.sops.yaml`, plaintext never on argv, scratch in tmpfs and shredded.
  Dotenv values containing `$` are single-quoted automatically (ledger #30).

## Hash-derived credentials

vaultwarden ADMIN_TOKEN (argon2id), backrest admin (bcrypt+b64), qbittorrent
(PBKDF2), wealthfolio (argon2id): a strong password is drawn, the **hash**
goes into the stack's `.sops.env`, and the **plaintext** is escrowed in
`secrets-recovery.sops.yaml` (repo root, same age key) and printed once.
Central file on purpose: every `.sops.env` key becomes a container env var,
and `decrypt-sops-envs` only globs literal `.sops.env` names — the recovery
file never reaches a container. If you prefer in-file recovery instead, move
the plaintext to an `UNUSED_<KEY>` key in the same `.sops.env` and drop the
`recovery:` field (accepting that it then rides into the container env).
qbittorrent needs no recovery entry — its plaintext is a real env key already.

## Manifest schema

```yaml
version: 1
recovery_file: secrets-recovery.sops.yaml
files:                                    # every file sops-gen may touch
  - { path: stacks/x/.sops.env, format: dotenv, example: stacks/x/.sops.env.example }
secrets:
  - name: x/db                            # unique; the `rotate` handle
    class: generate                       # generate | derived | pull | config
    recipe: hex:48                        # see recipes below
    freeze: true                          # optional: rotate needs --force
    copy_only: true                       # optional: propagate only, never draw
    recovery: X_ADMIN_PASSWORD            # optional: escrow key for the plaintext draw
    note: "..."                           # shown in reports; pull: how to obtain
    reminder: "..."                       # printed after a fill (manual follow-ups)
    deps: [other-entry]                   # optional: must be defined earlier
    targets:                              # >1 target = twins, one draw
      - { file: stacks/x/.sops.env, key: POSTGRES_PASSWORD }
      - { file: stacks/x/.sops.env, key: DATABASE_URL,
          template: "postgres://x:${v}@x_db:5432/x" }   # ${v} = rendered value
      - { file: stacks/x/.sops.env, key: HASH, part: argon2 }
```

Recipes: `hex:N` (N hex **chars**), `base64:N` (N random **bytes**, b64),
`alnum:N`, `uuid`, `wg`, `ssh-ed25519`, `cmd:...` (escape hatch).
Target `part`: `plain` (default), `bcrypt`, `bcrypt_b64`, `argon2`,
`pbkdf2_qbit`, `htpasswd:USER`, and for keypair recipes `private`,
`private_b64`, `public`. yaml keys nest with `/` (`ssh/github`).

Missing-file creation copies the `.sops.env.example` verbatim (comments and
key order included, so `stack-env-drift` parity holds), substituting only the
generate-class values; pull/config keys keep their `changeme` placeholders.

After any run: `git diff`, `./tests/run.sh`, commit atomically.
