#!/usr/bin/env bash
#
# Pre-backup preparation. Invoked by backup-prepare.service shortly before
# Backrest's snapshot window.
#
# This runs on the HOST, deliberately. The previous design ran the equivalent
# as a Backrest command hook inside the container, which could not work:
#
#   - the backrest image ships neither the docker CLI nor sqlite3
#   - it wrote dumps into /mnt/fast, which is mounted read-only in that container
#   - the hook was registered ON_ERROR_CANCEL, so its failure cancelled every
#     snapshot — a backup system that looked configured and produced nothing
#
# Every output is written to a .tmp and renamed only on success, so a failed
# dump never silently replaces the last good one with a truncated file.
#
# Note: no `set -e`. One failing service must not skip the rest; failures are
# accumulated and reported via the exit code, which trips OnFailure -> Ntfy.

set -uo pipefail

DUMPS=/mnt/fast/_dumps
VPSDIR=/mnt/fast/_vps
VPS_HOST="${VPS_HOST:-headscale-vps.tailnet.idanreed.com}"
VPS_USER="${VPS_USER:-idan}"
VPS_KEY="${VPS_KEY:-/var/lib/backup/vps_ed25519}"

rc=0
log() { echo "[backup-prepare] $*"; }

install -d -m 0700 "$DUMPS" "$VPSDIR"

running() { docker ps --format '{{.Names}}' | grep -qx "$1"; }

# ---------------------------------------------------------------------------
# PostgreSQL
# ---------------------------------------------------------------------------
# pg_dumpall against the container's superuser. A logical dump is restorable;
# a file-level copy of a live pgdata directory generally is not, which is why
# the Backrest plans exclude **/pgdata/**.
for svc in paperless immich firefly dawarich tandoor wger windmill; do
    container="${svc}_db"
    running "$container" || continue

    log "pg_dumpall $svc"
    if docker exec "$container" pg_dumpall -U "$svc" > "$DUMPS/$svc.sql.tmp"; then
        mv -f "$DUMPS/$svc.sql.tmp" "$DUMPS/$svc.sql"
    else
        log "FAILED: pg_dumpall $svc"
        rm -f "$DUMPS/$svc.sql.tmp"
        rc=1
    fi
done

# ---------------------------------------------------------------------------
# MySQL / MariaDB
# ---------------------------------------------------------------------------
# 🚨 `mariadb-dump`, NOT `mysqldump`. MariaDB 11.x DROPPED the mysql* symlinks
# entirely — `mariadb:11.8.9` ships mariadb-dump, mariadb-admin, mariadb-check
# and so on, and no `mysqldump` at all. The old name fails with exit 127
# ("exec: mysqldump: not found"), which does at least set rc=1 and reach ntfy,
# but it means BookStack would have had NO backup from the day it deployed.
# Caught by tests/suites/tracking.nix, which runs this exact command rather
# than an approximation of it.
#
# The ENV VAR keeps the MYSQL_ spelling: the image's entrypoint still accepts
# MYSQL_ROOT_PASSWORD as an alias for MARIADB_ROOT_PASSWORD, and
# stacks/tracking/compose.yaml sets it that way deliberately so this line can
# read it out of the container's own environment.
# DocSpace's portal database (stacks/docspace/compose.yaml). MySQL 8.4, which
# unlike MariaDB 11 DOES still ship `mysqldump` — the rename that broke the
# BookStack branch above was specifically MariaDB dropping its mysql* symlinks,
# and it does not apply here.
if running docspace_db; then
    log "mysqldump docspace"
    if docker exec docspace_db sh -c \
        'exec mysqldump -u root -p"$MYSQL_ROOT_PASSWORD" --all-databases' \
        > "$DUMPS/docspace.sql.tmp"; then
        mv -f "$DUMPS/docspace.sql.tmp" "$DUMPS/docspace.sql"
    else
        log "FAILED: mysqldump docspace"
        rm -f "$DUMPS/docspace.sql.tmp"
        rc=1
    fi
fi

if running bookstack_db; then
    log "mariadb-dump bookstack"
    if docker exec bookstack_db sh -c \
        'exec mariadb-dump -u root -p"$MYSQL_ROOT_PASSWORD" --all-databases' \
        > "$DUMPS/bookstack.sql.tmp"; then
        mv -f "$DUMPS/bookstack.sql.tmp" "$DUMPS/bookstack.sql"
    else
        log "FAILED: mariadb-dump bookstack"
        rm -f "$DUMPS/bookstack.sql.tmp"
        rc=1
    fi
fi

# ---------------------------------------------------------------------------
# SQLite
# ---------------------------------------------------------------------------
# `.backup` is safe against a live writer. Copying a WAL-mode database file
# directly is not — it can capture a torn page set with an out-of-date -wal.
sqlite_backup() {
    local name="$1" src="$2"
    [ -f "$src" ] || return 0

    log "sqlite backup $name"
    if sqlite3 "$src" ".backup '$DUMPS/$name.sqlite.tmp'"; then
        mv -f "$DUMPS/$name.sqlite.tmp" "$DUMPS/$name.sqlite"
    else
        log "FAILED: sqlite backup $name"
        rm -f "$DUMPS/$name.sqlite.tmp"
        rc=1
    fi
}

sqlite_backup vaultwarden    /mnt/fast/vaultwarden/db.sqlite3
# Karakeep keeps TWO sqlite databases under DATA_DIR: the app database and a
# separate job queue (liteque). This path used to read
# /mnt/fast/karakeep/data.db, which the app never creates — and since
# sqlite_backup returns 0 for a missing source, that line backed up nothing at
# all, forever, with a clean exit. Both paths are asserted by the tracking
# suite so it cannot silently regress. The queue is reconstructible, but it is
# a few KB and dumping it costs nothing.
sqlite_backup karakeep       /mnt/fast/karakeep/data/db.db
sqlite_backup karakeep-queue /mnt/fast/karakeep/data/queue.db
sqlite_backup homebox        /mnt/fast/homebox/homebox.db
# NO uptimekuma LINE. It used to be here, for a stack that has never been
# built — a permanently-silent no-op, since sqlite_backup returns 0 for a
# missing source. Removed rather than left "ready": a speculative backup
# line is indistinguishable from a working one until the day you need it,
# and the backup-coverage lint now fails on exactly this shape. Add it back
# together with the stack, not before. (Monitoring is also moving to Gatus,
# which is config-file-only and has no database to dump — see
# ServerNotes/designs/service-monitoring-stack-research.md.)
sqlite_backup homeassistant  /mnt/fast/homeassistant/home-assistant_v2.db
# Frigate's event/review/user index (stacks/automation/compose.yaml). WAL-mode
# and continuously written, like the recorder DB above and the arr databases
# below, so the raw file inside the /mnt/fast include set is a torn snapshot
# and this dump is the restorable copy. The recordings under /mnt/slow/frigate
# are deliberately not backed up at all — they are re-recordable and the slow
# plan's include list omits them.
sqlite_backup frigate        /mnt/fast/frigate/config/frigate.db
sqlite_backup audiobookshelf /mnt/fast/audiobookshelf/config/absdatabase.sqlite
# The other two books-stack databases (stacks/books/compose.yaml). Kavita's is
# WAL-mode by default since 0.8.2, so the raw file inside the /mnt/fast include
# set can snapshot torn — same reason as the arr databases below. Both paths
# are asserted to exist by the books suite, so a layout change in a future
# image fails a test instead of silently skipping (sqlite_backup returns 0 for
# a missing source).
sqlite_backup kavita         /mnt/fast/kavita/config/kavita.db
# Shelfmark's users.db is not documented upstream but was VERIFIED from a
# books-suite run (alongside settings.json and .flask_secret in /config). Both
# books paths are asserted to exist by that suite, so a layout change in a
# future image fails a test instead of silently skipping — sqlite_backup
# returns 0 for a missing source.
sqlite_backup shelfmark      /mnt/fast/shelfmark/config/users.db

# The arr databases are WAL-mode and written continuously (queue/history/RSS
# churn), so the raw files inside the /mnt/fast include set can snapshot as a
# torn page set with an out-of-date -wal — same reason as the rest of this
# section. Paths follow the /config binds in stacks/media/compose.yaml
# (LSIO layout: <db>.db at the config root; bazarr keeps its under db/).
# The sibling logs.db files are deliberately NOT dumped — they are log churn,
# rebuilt on start, and worthless in a restore.
sqlite_backup radarr         /mnt/fast/radarr/config/radarr.db
sqlite_backup sonarr         /mnt/fast/sonarr/config/sonarr.db
sqlite_backup prowlarr       /mnt/fast/prowlarr/config/prowlarr.db
sqlite_backup bazarr         /mnt/fast/bazarr/config/db/bazarr.db
sqlite_backup jellyfin       /mnt/fast/jellyfin/config/data/jellyfin.db
sqlite_backup jellyfin-lib   /mnt/fast/jellyfin/config/data/library.db
sqlite_backup seerr          /mnt/fast/seerr/config/db/db.sqlite3
# Cleanuparr's EF-Core sqlite lives somewhere under /mnt/fast/cleanuparr and
# its filename is UNVERIFIED (v2 is UI-configured; the DB appears at first
# setup) — it gets the raw-copy path only until the name is pinned down.
# All of the above paths are asserted to exist by the media suite, so a
# layout change in a future image fails a test instead of silently skipping.

# Beszel's hub is PocketBase, which keeps TWO databases side by side.
# data.db holds the collections that matter — systems, users, and every
# system_stats row, i.e. the entire metric history this stack exists to
# accumulate. auxiliary.db is PocketBase's own request/error log and is
# deliberately NOT backed up: it is regenerated, it is the larger of the two,
# and losing it costs nothing.
#
# Note both run in WAL mode, and at the moment of writing this data.db was 4 KB
# with an 853 KB -wal beside it — a plain file copy of data.db would have
# captured almost nothing. `sqlite3 .backup` is what makes this correct, which
# is the reason this helper exists rather than a cp.
#
# NOT backed up here and deliberately so: id_ed25519 and config.yml in the same
# directory. Both are regenerated from stacks/beszel/.sops.env by beszel-init
# on the next deploy, so the encrypted repo is already their backup.
sqlite_backup beszel         /mnt/fast/beszel/data.db

# ---------------------------------------------------------------------------
# VPS state
# ---------------------------------------------------------------------------
# Nothing else backs up the VPS. Losing that disk means:
#   - every node must re-enrol      (headscale db.sqlite + noise/DERP keys)
#   - every user must re-enrol TOTP (authentik identity database)
# Both are small; this is the cheapest large risk reduction available.
ssh_opts=(-i "$VPS_KEY" -o BatchMode=yes -o ConnectTimeout=10
          -o StrictHostKeyChecking=accept-new)

# The key is sops-managed (nixos/secrets.sops.yaml: BACKUP_VPS_SSH_KEY,
# installed by sops-nix at $VPS_KEY). Two unusable states, both loud through
# the same rc=1 -> OnFailure -> ntfy path: the file missing entirely, and the
# file present but still holding the committed template's changeme_
# placeholder — a fresh deploy installs that verbatim, ssh would then fail
# late and cryptically on an invalid key format, so refuse up front instead.
vps_key_problem=""
if [ ! -f "$VPS_KEY" ]; then
    vps_key_problem="missing"
elif grep -q '^changeme_' "$VPS_KEY"; then
    vps_key_problem="still a changeme_ placeholder"
fi

if [ -n "$vps_key_problem" ]; then
    log "WARNING: $VPS_KEY $vps_key_problem - VPS state is NOT being backed up."
    log "  Put the real private key in nixos/secrets.sops.yaml:"
    log "    sops nixos/secrets.sops.yaml      # BACKUP_VPS_SSH_KEY, block scalar"
    log "  then deploy, and authorise its public half on the VPS via"
    log "  ssh-pubkeys.nix (backup-vps) — see CLAUDE.md 'SSH identities'."
    rc=1
else
    log "authentik pg_dumpall (via $VPS_HOST)"
    if ssh "${ssh_opts[@]}" "$VPS_USER@$VPS_HOST" \
        'sudo docker exec authentik_db pg_dumpall -U authentik' \
        > "$VPSDIR/authentik.sql.tmp"; then
        mv -f "$VPSDIR/authentik.sql.tmp" "$VPSDIR/authentik.sql"
    else
        log "FAILED: authentik dump"
        rm -f "$VPSDIR/authentik.sql.tmp"
        rc=1
    fi

    # Headscale keeps db.sqlite plus noise_private.key and
    # derp_server_private.key here. The keys are the control-plane identity:
    # lose them and every client must re-authenticate.
    log "headscale state pull"
    if ! rsync -a --delete \
        --rsync-path='sudo rsync' \
        -e "ssh ${ssh_opts[*]}" \
        "$VPS_USER@$VPS_HOST:/var/lib/headscale/" "$VPSDIR/headscale/"; then
        log "FAILED: headscale state pull"
        rc=1
    fi
fi

if [ "$rc" -eq 0 ]; then
    log "complete"
    # Local canary. backup-staleness-check.timer alerts if this stamp goes
    # stale, which catches "the timer silently stopped firing" — a failure mode
    # that by definition produces no failure notification. The external
    # dead-man's switch (DEADMAN_URL in stacks/backrest) covers the case where
    # this whole host is down.
    date -u +%s > "$DUMPS/.last-success"
else
    log "completed WITH FAILURES"
fi
exit "$rc"
