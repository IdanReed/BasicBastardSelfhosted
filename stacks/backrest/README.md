# Backrest — restic backups to Hetzner Storage Box

Daily encrypted, deduplicated backups of everything except re-downloadable
media. Backrest provides scheduling and a browse/restore UI on top of restic.

## What backs up what

| Layer | Runs where | Does what |
|---|---|---|
| `backup-prepare.service` (02:45) | **host**, `nixos/backup-prepare.sh` | Postgres/MySQL/SQLite dumps into `/mnt/fast/_dumps`, and pulls VPS state into `/mnt/fast/_vps` |
| `fast-volume` plan (03:00) | Backrest container | `/mnt/fast` → restic |
| `slow-volume-selective` plan (04:00) | Backrest container | books, photos (immich originals; thumbs/encoded-video excluded — regenerable), samba → restic |

Dumps run on the host, not as a Backrest hook. The Backrest image has neither
the docker CLI nor `sqlite3`, `/mnt/fast` is mounted read-only inside it, and
the hook the original design specified was registered `ON_ERROR_CANCEL` — so
its guaranteed failure would have cancelled every snapshot.

Live database directories (`**/pgdata/**`) are **excluded**. A file-level copy
of a running Postgres cluster is torn and generally not restorable; the logical
dumps are what get backed up.

## One-time setup

These are the steps that cannot live in git.

### 1. Storage Box + sub-account

Order a Hetzner Storage Box (BX11 1 TB is enough to start). In the console:

- Create a **sub-account** scoped to its own directory. Restic authenticates
  with full write access to whatever it can see; a sub-account limits the blast
  radius.
- **Enable snapshots** (daily, keep 7–14). This is the single highest-value
  control here and it is a checkbox.

  Restic over SFTP has no append-only mode (that needs `rest-server`), so a
  compromised or malfunctioning services VM can run `restic forget --prune`, or
  encrypt itself, and take the backups with it. Storage Box snapshots are what
  make that recoverable.

### 2. SSH key

**Sops-managed** (see CLAUDE.md "SSH identities") — do NOT `ssh-keygen`
directly into `/var/lib/backup/`: sops-nix and a tmpfiles `C+` rule own both
paths there and will **overwrite a hand-made key on the next boot or
switch**, orphaning whatever public half you already authorised.

Generate locally, then put each half where it belongs:

```bash
ssh-keygen -t ed25519 -N "" -f /tmp/storagebox_ed25519
# private half -> BACKUP_STORAGEBOX_SSH_KEY in nixos/secrets.sops.yaml:
sops nixos/secrets.sops.yaml           # paste as a YAML block scalar
# public half -> the backup-storagebox entry in all three ssh-pubkeys.nix
# copies, and authorised on the box:
ssh-copy-id -p 23 -i /tmp/storagebox_ed25519.pub \
    uXXXXXX@uXXXXXX.your-storagebox.de
shred -u /tmp/storagebox_ed25519*
```

Then fill in `uXXXXXX` in `ssh_config`. The key materialises on the host at
`/var/lib/backup/storagebox_ed25519` (a real file re-copied from
`/run/secrets` each boot, because backrest bind-mounts the directory and a
symlink would dangle inside the container). `config-init` refuses to seed —
and Backrest will not start — while the key is missing **or still the
`changeme_` placeholder**, rather than coming up and failing every backup on
ssh auth.

### 3. VPS backup key

`backup-prepare.sh` pulls the Authentik identity database and the Headscale
node database + private keys over the tailnet. Nothing else backs up the VPS.

Same sops flow: private half → `BACKUP_VPS_SSH_KEY` in
`nixos/secrets.sops.yaml` (sops-nix symlinks it to
`/var/lib/backup/vps_ed25519`), public half → the `backup-vps` entry in the
three `ssh-pubkeys.nix` copies — the VPS authorises it from there, no
`ssh-copy-id` needed once deployed.

Until the real value is in, `backup-prepare.service` warns (missing **or**
`changeme_` placeholder) and exits non-zero, which trips `OnFailure=` → Ntfy.
That is deliberate: a missing VPS backup should be noisy, not silent.

### 4. Secrets

Copy `.sops.env.example` → `.sops.env`, fill in, encrypt. The admin password
goes in as **base64 of the bcrypt hash** (see the generate command in the
example) — Backrest base64-decodes `passwordBcrypt` before comparing, so a raw
bcrypt can never log in. Any value containing `$` (e.g. a generated
`RESTIC_PASSWORD`) must be single-quoted before encrypting — the
decrypt-and-source path would otherwise expand it.

### 5. Dead-man's switch

Set `DEADMAN_URL` to a healthchecks.io check (or equivalent). The hook is
`actionHealthchecks`, so delivery is healthchecks-style: success pings the
URL, failure pings `<URL>/fail` — richer than the old bare POST. This is the only
thing that catches *absence* — a backup that stopped running produces no
failure notification, because nothing runs to fail. Success notifications train
you to ignore them; absence detection does not.

## Offline recovery artifact

The one part of this system with no digital redundancy, by design. If it is
lost, the backups are unreadable and nothing else matters.

It must contain:

1. The **age private key** (`sops_age_key.txt`) — decrypts every `.sops.env`.
2. The **restic repository password** — decrypts the backup repository.
3. **Storage Box credentials** — sub-account username, password, hostname.

Store it *outside this infrastructure*: printed and filed, or on an encrypted
USB kept off-site, plus a copy in a password manager you do **not** self-host.

Do not store these only in Vaultwarden. Vaultwarden runs here, and its backup
is encrypted with exactly these credentials — the circular dependency means a
total loss of this host would leave you unable to decrypt the backup of the
thing holding the keys. The same trap as storing your TOTP seeds in the
password manager that TOTP protects.

Disaster recovery therefore starts at step 0: retrieve this artifact.

## Restore

### Via the UI

`https://backrest.svc.idanreed.com` → repository → Browse Snapshots → restore.

### Database restore

Restores come from the dumps in `/mnt/fast/_dumps`, not from `pgdata`:

```bash
# 1. Restore the dump
docker exec -it backrest restic -r sftp:storagebox:/home/restic \
    restore latest --target /tmp/restore --include /mnt/fast/_dumps/paperless.sql

# 2. Stop the app, keep the database up
docker stop paperless

# 3. Load it
docker exec -i paperless_db psql -U paperless < \
    /tmp/restore/mnt/fast/_dumps/paperless.sql

# 4. Start
docker start paperless
```

### VPS restore

```bash
# Authentik identity database
docker exec -i authentik_db psql -U authentik < _vps/authentik.sql

# Headscale: stop the service, restore state, start it. The private keys
# matter as much as the database — without noise_private.key every client
# must re-authenticate.
sudo systemctl stop headscale
sudo rsync -a _vps/headscale/ /var/lib/headscale/
sudo chown -R headscale:headscale /var/lib/headscale
sudo systemctl start headscale
```

### Verify restores actually work

`checkPolicy` runs `restic check --read-data-subset 5%` monthly, which proves
the repository is readable. It does **not** prove a dump is loadable. Test a
real restore of Paperless and Vaultwarden into a scratch container at least
once, and again after any major version bump — an untested restore is a
hypothesis, not a backup.
