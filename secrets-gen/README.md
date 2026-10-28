# secrets-gen

`sops-gen` + `manifest.yaml`: generate-if-absent secret management over sops.
Fills every `generate`- and `derived`-class entry in `manifest.yaml`, refuses the
`pull`-class ones (they are minted elsewhere), and never overwrites real
committed key material. The inventory grouped by bring-up step is
[`docs/bring-up.md`](../docs/bring-up.md) §4.

A value is stored ONCE, so most entries have a single target. Cross-host values
live in `secrets/shared.sops.json`; values built from others (a URL around a
password, an app's copy of a shared OIDC secret) are the stack's `env.nix`,
rendered by sops-nix on the host — never a manifest target. Multiple targets
remain only for hashes of one draw (a login password and its bcrypt/PBKDF2).

```bash
nix-shell secrets-gen/shell.nix          # sops, age, openssl, yq, wg, htpasswd, argon2, xxd
secrets-gen/sops-gen apply --dry-run     # read-only plan: plaintext key grep, no decryption
SOPS_AGE_KEY="$(sudo cat /var/lib/sops-nix/sops_age_key.txt)" secrets-gen/sops-gen apply
```

## Subcommands

| Command | Needs key | Does |
| --- | --- | --- |
| `apply --dry-run` | no | plan only — no writes, no decryption |
| `apply` | for full run | fill absent/`^changeme` values; create a missing `secrets.sops.json` from its `secrets.example.env` (pubkey-only) |
| `rotate NAME [--force]` | yes | force-regenerate one entry (`--force` for frozen) |
| `sort [--dry-run] [FILE]` | yes | reorder a yaml/dotenv file's keys to its example's order (JSON is skipped) |
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
- **Twins** (a password and its hashes): one draw per entry, rendered into
  every target in one pass. If one target is already real, that value is
  *propagated*, never redrawn; `copy_only` entries (`user/idan`) never draw
  at all.
- All writes go through `sops set --value-stdin` / `sops encrypt` — recipient
  from `.sops.yaml`, plaintext never on argv, scratch in tmpfs and shredded.
  Dotenv values containing `$` are single-quoted automatically
  (`tests/README.md`, rule #30).

## sort

The `.example` carries the grouping (`# Postgres`, `# OIDC`, …); its encrypted
twin cannot be reordered without the age key, so `sort` is the operator step
that lands it. Decrypt → reorder → re-encrypt (tmpfile+rename), printing a
key-order diff. Only ORDER changes: every line is copied verbatim (values,
single-quoting, YAML block scalars), each key's leading comments travel with
it, keys absent from the example are pushed to the end, and a reorder that
would alter content is refused before anything is written. Nested YAML keys
(`ssh/*`) stay inside their parent, and everything above the first key stays on
top as the file header (sops drops blank lines in both stores, so a comment
written for the first key is indistinguishable from a header and stays put).
`--dry-run` decrypts and reports only;
`--example FILE` orders against a different template (how the test fixtures
are kept in step with their stack's example).

```bash
sopsgen sort --dry-run                       # every managed file: what would move
sopsgen sort nixos/secrets.sops.yaml         # one file
```

## Hash-derived credentials

vaultwarden ADMIN_TOKEN (argon2id), backrest admin (bcrypt+b64), qbittorrent
(PBKDF2), wealthfolio (argon2id): a strong password is drawn, the **hash**
goes into the stack's `secrets.sops.json`, and the **plaintext** is escrowed in
`secrets-recovery.sops.yaml` (repo root, same age key) and printed once.
Central file on purpose: every stored stack key becomes a container env var,
and no host reads the recovery file — it never reaches a container. The
backrest and qBittorrent hashes are of `IDAN_INITIAL_PASSWORD`, whose plaintext
is already in `secrets/shared.sops.json`, so they need no recovery entry.

## Manifest schema

```yaml
version: 1
recovery_file: secrets-recovery.sops.yaml
files:                                    # every file sops-gen may touch
  - { path: stacks/x/secrets.sops.json, format: json, example: stacks/x/secrets.example.env }
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
    targets:                              # >1 target = one draw, several forms
      - { file: stacks/x/secrets.sops.json, key: ADMIN_PASSWORD }
      - { file: stacks/x/secrets.sops.json, key: ADMIN_URL,
          template: "https://admin:${v}@x" }   # ${v} = rendered value
      - { file: stacks/x/secrets.sops.json, key: HASH, part: argon2 }
      - { file: secrets/shared.sops.json, key: PW, source: true }  # copy_only:
          # the one hand-set target; `rotate` re-derives all others from it
```

Target `source: true` (copy_only only): marks the single target that holds the
hand-set canonical plaintext. `rotate <name>` reads it and re-derives every
other target — plain copies verbatim, hash parts freshly hashed — so one edit
fans out to all copies and hashes. `apply` still only fills missing/`changeme`
and refuses on diverged twins; use `rotate` to push a change.

Recipes: `hex:N` (N hex **chars**), `base64:N` (N random **bytes**, b64),
`alnum:N`, `uuid`, `wg`, `ssh-ed25519`, `cmd:...` (escape hatch).
Target `part`: `plain` (default), `bcrypt`, `bcrypt_b64`, `argon2`,
`pbkdf2_qbit`, `htpasswd:USER`, and for keypair recipes `private`,
`private_b64`, `public`. yaml keys nest with `/` (`ssh/github`).

Missing-file creation reads the example's `KEY=value` lines into a JSON object
(`format: json`) or copies the example verbatim (yaml/dotenv), substituting
only the generate-class values; pull/config keys keep their `changeme`
placeholders. (`stack-env-drift` compares key SETS, not order.)

`recovery_file:` is separate from `files:`, so the recovery escrow is written
and read but never listed by `list` / `view` / `search`.

After any run: `git diff`, `./tests/run.sh`, commit atomically.
