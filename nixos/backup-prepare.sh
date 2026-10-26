#!/usr/bin/env bash
#
# Pre-backup preparation, run by backup-prepare.service before Backrest's
# window. On the host, not as a Backrest command hook: that image ships neither
# the docker CLI nor sqlite3, /mnt/fast is read-only there, and an
# ON_ERROR_CANCEL hook failure cancels every snapshot.
#
# No `set -e`: one failing service must not skip the rest. Failures accumulate
# into the exit code, which trips OnFailure -> ntfy.

set -uo pipefail

DUMPS=/mnt/fast/_dumps
VPSDIR=/mnt/fast/_vps
VPS_HOST="${VPS_HOST:-headscale-vps.tailnet.idanreed.com}"
VPS_USER="${VPS_USER:-idan}"
VPS_KEY="${VPS_KEY:-/var/lib/backup/vps_ed25519}"

# Escape hatch, space-separated, matched against stack or container name: a
# deliberately-stopped stack would otherwise page every night. An env var on
# the unit rather than a marker file, because Periphery owns its clones under
# /srv/komodo/stacks and would overwrite one dropped there.
BACKUP_SKIP="${BACKUP_SKIP:-}"

# Two counters, not one: the exit code aggregates, but the success stamps are
# separate so an unreachable VPS does not suppress the local-dump stamp.
rc_local=0
rc_vps=0

log() { echo "[backup-prepare] $*"; }

install -d -m 0700 "$DUMPS" "$VPSDIR"

running() { docker ps --format '{{.Names}}' | grep -qx "$1"; }
exists()  { docker ps -a --format '{{.Names}}' | grep -qx "$1"; }

# Is this database expected to be running? A bare skip-on-not-running would
# leave a crash-looping database silently absent from a green backup. Three
# states, only the first two benign:
#
#   not deployed  no container was ever created. The dump list legitimately
#                 runs ahead of the build-out, so this is a silent success.
#   skipped       named in BACKUP_SKIP. Logged, not alerted.
#   expected      container EXISTS but is not running: a real hole in tonight's
#                 backup, so rc_local=1 and ntfy.
#
# Returns nonzero in all three; the caller skips the dump either way.
require_running() {
    local container="$1" stack="$2"
    running "$container" && return 0

    case " $BACKUP_SKIP " in
        *" $stack "* | *" $container "*)
            log "SKIP: $container (listed in BACKUP_SKIP)"
            return 1
            ;;
    esac

    if exists "$container"; then
        log "FAILED: container $container exists but is NOT running - $stack has no dump in this backup"
        log "  if $stack is deliberately stopped, add it to BACKUP_SKIP= on backup-prepare.service"
        rc_local=1
        return 1
    fi
    log "skip: $stack is not deployed on this host (no $container container)"
    return 1
}

# Rename a finished dump into place, but only if it has content: a command that
# exits 0 having written nothing must not replace the last good dump. A
# zero-byte result is always a fault — `sqlite3 .backup` of an empty source
# still emits a one-page database and pg_dumpall still emits its header.
finish_dump() {
    local tmp="$1" final="$2" label="$3"
    if [ ! -s "$tmp" ]; then
        log "FAILED: $label exited 0 but produced a ZERO-BYTE dump - NOT replacing $final"
        rm -f "$tmp"
        return 1
    fi
    mv -f "$tmp" "$final"
}

# ---------------------------------------------------------------------------
# PostgreSQL
# ---------------------------------------------------------------------------
# A logical dump is restorable; a file-level copy of a live pgdata directory
# generally is not, which is why the Backrest plans exclude **/pgdata/**.
#
# Every entry expects container <svc>_db with superuser <svc> (POSTGRES_USER);
# the backup-coverage lint checks both against the compose files. komodo is the
# deploy plane's own state — FerretDB keeps all of it as JSONB in this cluster.
for svc in paperless immich firefly dawarich tandoor wger windmill outline ghostfolio komodo excalidraw; do
    container="${svc}_db"
    require_running "$container" "$svc" || continue

    log "pg_dumpall $svc"
    if docker exec "$container" pg_dumpall -U "$svc" > "$DUMPS/$svc.sql.tmp"; then
        finish_dump "$DUMPS/$svc.sql.tmp" "$DUMPS/$svc.sql" "pg_dumpall $svc" || rc_local=1
    else
        log "FAILED: pg_dumpall $svc"
        rm -f "$DUMPS/$svc.sql.tmp"
        rc_local=1
    fi
done

# ---------------------------------------------------------------------------
# MySQL / MariaDB
# ---------------------------------------------------------------------------
# MYSQL_PWD, not `-p"$PASSWORD"`: /proc/<pid>/cmdline is world-readable on the
# host, /proc/<pid>/environ is not. Both clients honour it (finding #35).
#
# DocSpace is MySQL 8.4, which still ships `mysqldump`. MariaDB 11 does not —
# see bookstack below.
if require_running docspace_db docspace; then
    log "mysqldump docspace"
    if docker exec docspace_db sh -c \
        'MYSQL_PWD="$MYSQL_ROOT_PASSWORD"; export MYSQL_PWD; exec mysqldump -u root --all-databases' \
        > "$DUMPS/docspace.sql.tmp"; then
        finish_dump "$DUMPS/docspace.sql.tmp" "$DUMPS/docspace.sql" "mysqldump docspace" || rc_local=1
    else
        log "FAILED: mysqldump docspace"
        rm -f "$DUMPS/docspace.sql.tmp"
        rc_local=1
    fi
fi

# `mariadb-dump`, NOT `mysqldump`: MariaDB 11.x dropped the mysql* symlinks.
# BookStack lives in the tracking stack, so the container and stack names
# differ — the one place in this script where they do.
if require_running bookstack_db tracking; then
    log "mariadb-dump bookstack"
    if docker exec bookstack_db sh -c \
        'MYSQL_PWD="$MYSQL_ROOT_PASSWORD"; export MYSQL_PWD; exec mariadb-dump -u root --all-databases' \
        > "$DUMPS/bookstack.sql.tmp"; then
        finish_dump "$DUMPS/bookstack.sql.tmp" "$DUMPS/bookstack.sql" "mariadb-dump bookstack" || rc_local=1
    else
        log "FAILED: mariadb-dump bookstack"
        rm -f "$DUMPS/bookstack.sql.tmp"
        rc_local=1
    fi
fi

# ---------------------------------------------------------------------------
# SQLite
# ---------------------------------------------------------------------------
# `.backup` is safe against a live writer; copying a WAL-mode file is not (a
# raw copy of forgejo's gitea.db held 73 tables, the .backup 131).
#
# A MISSING source returns 0, so a wrong path backs up nothing forever with a
# clean exit — every path below is asserted by its stack's suite.
sqlite_backup() {
    local name="$1" src="$2"
    [ -f "$src" ] || return 0

    log "sqlite backup $name"
    if sqlite3 "$src" ".backup '$DUMPS/$name.sqlite.tmp'"; then
        finish_dump "$DUMPS/$name.sqlite.tmp" "$DUMPS/$name.sqlite" "sqlite backup $name" || rc_local=1
    else
        log "FAILED: sqlite backup $name"
        rm -f "$DUMPS/$name.sqlite.tmp"
        rc_local=1
    fi
}

sqlite_backup vaultwarden    /mnt/fast/vaultwarden/db.sqlite3
# Mealie is sqlite on purpose; see its compose header.
sqlite_backup mealie         /mnt/fast/mealie/mealie.db
# Wealthfolio (evaluation). secrets.json beside it is covered as a file, useful
# only with WF_SECRET_KEY from secrets.sops.json.
sqlite_backup wealthfolio    /mnt/fast/wealthfolio/wealthfolio.db
# Karakeep keeps the app database and a separate liteque job queue.
sqlite_backup karakeep       /mnt/fast/karakeep/data/db.db
sqlite_backup karakeep-queue /mnt/fast/karakeep/data/queue.db
sqlite_backup homebox        /mnt/fast/homebox/homebox.db
# No uptimekuma line: the stack has never been built, and the backup-coverage
# lint fails on a speculative no-op. Monitoring is moving to Gatus anyway.
sqlite_backup homeassistant  /mnt/fast/homeassistant/home-assistant_v2.db
# Frigate's event/review index. Recordings under /mnt/slow/frigate are
# deliberately not backed up — re-recordable, and off the slow plan.
sqlite_backup frigate        /mnt/fast/frigate/config/frigate.db
sqlite_backup audiobookshelf /mnt/fast/audiobookshelf/config/absdatabase.sqlite
sqlite_backup kavita         /mnt/fast/kavita/config/kavita.db
# Shelfmark's users.db is undocumented upstream; verified from a books-suite run.
sqlite_backup shelfmark      /mnt/fast/shelfmark/config/users.db

# The arr databases follow the /config binds in stacks/media/compose.yaml
# (LSIO layout: <db>.db at the config root, bazarr's under db/). The sibling
# logs.db files are deliberately not dumped.
sqlite_backup radarr         /mnt/fast/radarr/config/radarr.db
sqlite_backup sonarr         /mnt/fast/sonarr/config/sonarr.db
sqlite_backup prowlarr       /mnt/fast/prowlarr/config/prowlarr.db
sqlite_backup bazarr         /mnt/fast/bazarr/config/db/bazarr.db
sqlite_backup jellyfin       /mnt/fast/jellyfin/config/data/jellyfin.db
sqlite_backup jellyfin-lib   /mnt/fast/jellyfin/config/data/library.db
sqlite_backup seerr          /mnt/fast/seerr/config/db/db.sqlite3
# Cleanuparr's EF-Core sqlite filename is UNVERIFIED (v2 creates it at first
# setup) — raw-copy path only until it is pinned down.

# Beszel's PocketBase hub. auxiliary.db beside it (request/error log) and the
# id_ed25519/config.yml that beszel-init regenerates are deliberately skipped.
sqlite_backup beszel         /mnt/fast/beszel/data.db

# Forgejo, the git root for this homelab: its compose configures no database,
# so the image falls back to sqlite at /data/gitea/gitea.db. Not `forgejo dump`
# — that zips the repositories, which the fast plan already copies file by
# file. app.ini beside it is covered as a file.
sqlite_backup forgejo        /mnt/fast/forgejo/data/gitea/gitea.db

# Ntfy's user/token/ACL database. The message cache is deliberately skipped.
sqlite_backup ntfy           /mnt/fast/ntfy/lib/auth.db

# Gatus's uptime/latency history; endpoint definitions are config in git.
sqlite_backup gatus          /mnt/fast/gatus/gatus.db

# Grafana's own state: dashboards, saved queries, users, API keys. Datasources
# and the admin credential are re-provisioned from git on every deploy.
#
# VictoriaLogs' store is deliberately NOT dumped and on no Backrest plan —
# see the NOT_BACKED_UP entry in tests/lib/lints.nix. This line is the whole of
# the logging stack's backup.
sqlite_backup grafana        /mnt/fast/grafana/grafana.db

# ---------------------------------------------------------------------------
# VPS state
# ---------------------------------------------------------------------------
# Nothing else backs up the VPS: losing that disk means every node re-enrols
# (headscale db + noise/DERP keys) and every user re-enrols TOTP (authentik).
ssh_opts=(-i "$VPS_KEY" -o BatchMode=yes -o ConnectTimeout=10
          -o StrictHostKeyChecking=accept-new)

# Refuse up front on the two unusable key states; ssh would otherwise fail late
# and cryptically on an invalid key format.
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
    rc_vps=1
else
    log "authentik pg_dumpall (via $VPS_HOST)"
    if ssh "${ssh_opts[@]}" "$VPS_USER@$VPS_HOST" \
        'sudo docker exec authentik_db pg_dumpall -U authentik' \
        > "$VPSDIR/authentik.sql.tmp"; then
        finish_dump "$VPSDIR/authentik.sql.tmp" "$VPSDIR/authentik.sql" "authentik dump" || rc_vps=1
    else
        log "FAILED: authentik dump"
        rm -f "$VPSDIR/authentik.sql.tmp"
        rc_vps=1
    fi

    # Headscale keeps db.sqlite plus noise_private.key and
    # derp_server_private.key here — the control-plane identity. It runs
    # WAL-mode, so snapshot on the VPS, pull that, and exclude the live files.
    # sqlite3 is provisioned in headscale-vps/configuration.nix.
    log "headscale sqlite snapshot (via $VPS_HOST)"
    snapshot_ok=1
    if ! ssh "${ssh_opts[@]}" "$VPS_USER@$VPS_HOST" \
        'sudo sqlite3 /var/lib/headscale/db.sqlite ".backup /var/lib/headscale/db-backup.sqlite"'; then
        log "FAILED: headscale sqlite snapshot"
        snapshot_ok=0
        rc_vps=1
    fi

    # The exclusions also protect the previous good snapshot from --delete when
    # tonight's fails, exactly as finish_dump does for the local dumps.
    log "headscale state pull"
    if ! rsync -a --delete \
        --exclude='db.sqlite' --exclude='db.sqlite-*' --exclude='db-backup.sqlite' \
        --rsync-path='sudo rsync' \
        -e "ssh ${ssh_opts[*]}" \
        "$VPS_USER@$VPS_HOST:/var/lib/headscale/" "$VPSDIR/headscale/"; then
        log "FAILED: headscale state pull"
        rc_vps=1
    fi

    # Lands under the live file's name: the DR path and the tailnet suite
    # expect _vps/headscale/db.sqlite. Pulled separately so it goes through
    # finish_dump's zero-byte guard and atomic rename.
    if [ "$snapshot_ok" -eq 1 ]; then
        if rsync -a --rsync-path='sudo rsync' -e "ssh ${ssh_opts[*]}" \
            "$VPS_USER@$VPS_HOST:/var/lib/headscale/db-backup.sqlite" \
            "$VPSDIR/headscale/db.sqlite.tmp"; then
            finish_dump "$VPSDIR/headscale/db.sqlite.tmp" \
                "$VPSDIR/headscale/db.sqlite" "headscale db snapshot" || rc_vps=1
        else
            log "FAILED: headscale db snapshot pull"
            rm -f "$VPSDIR/headscale/db.sqlite.tmp"
            rc_vps=1
        fi
    fi

    # A stale -wal beside a fresh snapshot is worse than none, and the
    # exclusions above mean rsync never clears them.
    rm -f "$VPSDIR/headscale/db.sqlite-wal" "$VPSDIR/headscale/db.sqlite-shm"
fi

# ---------------------------------------------------------------------------
# Success stamps
# ---------------------------------------------------------------------------
# Two stamps, read with two different windows by backup-staleness-check. A
# single stamp conflated two facts: a VPS blip skipped it and tripped the
# staleness alarm even though every local dump had worked.
if [ "$rc_local" -eq 0 ]; then
    date -u +%s > "$DUMPS/.last-success-local"
fi

if [ "$rc_vps" -eq 0 ]; then
    date -u +%s > "$DUMPS/.last-success-vps"
fi

# The single stamp the pair replaces: a stamp nothing writes but someone checks
# during an incident is worse than none.
rm -f "$DUMPS/.last-success"

rc=0
if [ "$rc_local" -ne 0 ] || [ "$rc_vps" -ne 0 ]; then
    rc=1
    log "completed WITH FAILURES (local=$rc_local vps=$rc_vps)"
else
    log "complete"
fi
exit "$rc"
