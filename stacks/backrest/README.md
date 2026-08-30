# Backrest — restic backups to Hetzner Storage Box

Daily encrypted, deduplicated backups of everything except re-downloadable
media. Backrest provides scheduling and a browse/restore UI on top of restic.

## What backs up what

| Layer | Runs where | Does what |
|---|---|---|
| `backup-prepare.service` (02:45) | **host**, `nixos/backup-prepare.sh` | Postgres/MySQL/SQLite dumps into `/mnt/fast/_dumps`, and pulls VPS state into `/mnt/fast/_vps` |
| `fast-volume` plan (03:00) | Backrest container | `/mnt/fast` → restic |
| `slow-volume-selective` plan (04:00) | Backrest container | books, immich, samba → restic |

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

Lives on the host, never in git or SOPS:

```bash
sudo ssh-keygen -t ed25519 -N "" -f /var/lib/backup/storagebox_ed25519
sudo ssh-copy-id -p 23 -i /var/lib/backup/storagebox_ed25519.pub \
    uXXXXXX@uXXXXXX.your-storagebox.de
```

Then fill in `uXXXXXX` in `ssh_config`. `config-init` refuses to seed and
Backrest will not start if the key is missing, rather than coming up and
failing every backup on ssh auth.

### 3. VPS backup key

`backup-prepare.sh` pulls the Authentik identity database and the Headscale
node database + private keys over the tailnet. Nothing else backs up the VPS.

```bash
sudo ssh-keygen -t ed25519 -N "" -f /var/lib/backup/vps_ed25519
sudo ssh-copy-id -i /var/lib/backup/vps_ed25519.pub \
    idan@headscale-vps.tailnet.idanreed.com
```

Until this exists, `backup-prepare.service` warns and exits non-zero, which
trips `OnFailure=` → Ntfy. That is deliberate: a missing VPS backup should be
noisy, not silent.

### 4. Secrets

Copy `.sops.env.example` → `.sops.env`, fill in, encrypt. Note the bcrypt hash
must be single-quoted before encrypting — it contains `$`, which the
decrypt-and-source path would otherwise expand.

### 5. Dead-man's switch

Set `DEADMAN_URL` to a healthchecks.io check (or equivalent). This is the only
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
