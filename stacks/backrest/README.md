# Backrest — restic to a Hetzner Storage Box

Nightly encrypted, deduplicated backups of everything except re-downloadable
media, with a browse/restore UI at `https://backrest.svc.idanreed.com`
(forward auth in front of Backrest's own login). The schedule, the routine
check and the restore drill are in
[docs/deploy.md](../../docs/deploy.md#backups-and-the-restore-drill); the
one-time setup is [docs/bring-up.md](../../docs/bring-up.md) §16.

## What backs up what

| Layer | Runs | Does |
|---|---|---|
| `backup-prepare.service`, 02:45 | on the host (`nixos/backup-prepare.sh`) | Postgres/MariaDB/SQLite dumps into `/mnt/fast/_dumps`; pulls the VPS's Authentik dump and headscale state into `/mnt/fast/_vps` |
| `fast-volume`, 03:00 | Backrest | `/mnt/fast` → restic |
| `slow-volume-selective`, 04:00 | Backrest | the `/mnt/slow` directories listed in `config.template.json` (books, photos without thumbnails or encoded video, the mail archive) → restic |

- **Dumps run on the host, not as a Backrest hook.** The Backrest image has
  neither the docker CLI nor `sqlite3`, and mounts `/mnt/fast` read-only.
- **`**/pgdata/**` is excluded.** A file copy of a running Postgres cluster is
  torn; the dumps are the backup.
- **Signals:** errors go to ntfy (shoutrrr over the `homelab` network);
  `fast-volume` success pings `DEADMAN_URL` (healthchecks.io), so a backup that
  stopped running is caught by its absence. Success is otherwise silent.

## Setup rules

- **The Storage Box** has a sub-account scoped to its own directory, and box
  snapshots on (daily, keep 7–14). restic over SFTP has no append-only mode, so
  a compromised VM could `forget --prune` the repo; the box's snapshots are
  what make that recoverable.
- **The SSH key is a sops value** (`BACKUP_STORAGEBOX_SSH_KEY` in
  `nixos/secrets.sops.yaml`; public half `backup-storagebox` in
  `ssh-pubkeys.nix`, authorised on the sub-account). A tmpfiles `C+` rule
  copies it to `/var/lib/backup/storagebox_ed25519` — a real file, because the
  containers bind-mount that path and a symlink into `/run/secrets` would
  dangle inside them — **only when the file is absent**: a hand-made key there
  shadows the sops value until deleted. Never `ssh-keygen` into
  `/var/lib/backup/`.
- **The host key is pinned.** `ssh_config` sets `StrictHostKeyChecking yes`
  against the committed `known_hosts` (Hetzner's keys, shared by every Storage
  Box, checked with `ssh-keygen -l -f known_hosts` against the fingerprints
  Hetzner publishes). A mismatch is not a rotation until Hetzner's docs say so.
- **`config-init` seeds `config.json` exactly once** and refuses to while the
  key is missing or a placeholder, the sub-account name in `ssh_config` is
  unedited, or any substituted value is empty or contains `changeme` — a
  placeholder seeded once would be permanent. After the seed, Backrest owns
  the file: a plan change in `config.template.json` reaches a live host only if
  it is also made in the UI.
- **The admin password is base64 of a bcrypt** (`BACKREST_ADMIN_PASSWORD_BCRYPT`,
  drawn from idan's password by `sopsgen`). Backrest base64-decodes
  `passwordBcrypt` before comparing, so a raw bcrypt never logs in.
- **The VPS pull key** (`BACKUP_VPS_SSH_KEY`, symlinked to
  `/var/lib/backup/vps_ed25519`) is authorised on the VPS from
  `ssh-pubkeys.nix`. While it is missing or a placeholder, `backup-prepare`
  fails loudly (`OnFailure` → ntfy).
- Each container mounts only the key it reads: `config-init` gets the Storage
  Box key file, never `/var/lib/backup` (which also holds the VPS key).

## Restore

The full-host restore is [docs/bring-up.md](../../docs/bring-up.md)
Appendix A; the VPS's Authentik database goes into a virgin cluster as in
§0.4. One database from a snapshot:

```bash
docker exec backrest restic -r sftp:storagebox:/home/restic \
  restore <snapshot-id> --target /tmp/restore --include /mnt/fast/_dumps/paperless.sql
docker cp backrest:/tmp/restore/mnt/fast/_dumps/paperless.sql /tmp/paperless.sql
docker stop paperless                                  # keep paperless_db up
docker exec -i paperless_db psql -U paperless < /tmp/paperless.sql
docker start paperless
```

`checkPolicy` runs `restic check --read-data-subset 5%` monthly: it proves the
repository is readable, not that a dump loads. The drill in
[docs/deploy.md](../../docs/deploy.md#backups-and-the-restore-drill) is the
control for that.
