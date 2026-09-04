#!/usr/bin/env bash
#
# Pre-backup preparation. Invoked by backup-prepare.service shortly before
# Backrest's snapshot window.
#
# Runs on the HOST, deliberately — an in-container Backrest hook cannot work:
# the image ships neither docker CLI nor sqlite3, /mnt/fast is read-only
# there, and an ON_ERROR_CANCEL hook failure cancels every snapshot.
#
# Every output is written to a .tmp and renamed only on success AND only when
# it has content, so a failed dump never silently replaces the last good one.
#
# No `set -e`: one failing service must not skip the rest; failures accumulate
# into the exit code, which trips OnFailure -> Ntfy.

set -uo pipefail

DUMPS=/mnt/fast/_dumps
VPSDIR=/mnt/fast/_vps
VPS_HOST="${VPS_HOST:-headscale-vps.tailnet.idanreed.com}"
VPS_USER="${VPS_USER:-idan}"
VPS_KEY="${VPS_KEY:-/var/lib/backup/vps_ed25519}"

# Where stack-git-sync lands the stacks. A directory here is this script's
# only evidence a stack is SUPPOSED to be running — see require_running.
STACKS="${STACKS:-/srv/stacks}"

# Escape hatch, space-separated, matched against stack or container name: a
# deliberately-stopped stack would otherwise page every night. An env var on
# the unit rather than a marker file, because stack-git-sync owns the
# contents of $STACKS and would overwrite one dropped there.
BACKUP_SKIP="${BACKUP_SKIP:-}"

# Two counters, not one: the exit code aggregates, but the success STAMPS are
# separate, so an unreachable VPS does not suppress the stamp certifying the
# local dumps. See the stamp block at the bottom.
rc_local=0
rc_vps=0

log() { echo "[backup-prepare] $*"; }

install -d -m 0700 "$DUMPS" "$VPSDIR"

running() { docker ps --format '{{.Names}}' | grep -qx "$1"; }
exists()  { docker ps -a --format '{{.Names}}' | grep -qx "$1"; }

# Is this database container expected to be running right now? A bare
# skip-on-not-running would leave a stopped or crash-looping database silently
# absent from the backup with a green run. Three states, only one fine:
#
#   not deployed  no container was ever created for it. Under the Komodo
#                 GitOps model stack-git-sync rsyncs EVERY stack DIR into
#                 $STACKS regardless of deployment, so a $STACKS/<stack> dir
#                 alone no longer implies deployed — only a created container
#                 does. The dump list legitimately runs ahead of the
#                 build-out, so this is a silent, successful skip.
#   skipped       named in BACKUP_SKIP. Logged, not alerted.
#   expected      container EXISTS but is not running: a deployed stack whose
#                 database is down = a real hole in tonight's backup —
#                 rc_local=1, OnFailure -> ntfy exactly like a dump that
#                 errored. (Pathological edge: a DB container docker-rm'd out
#                 from under a live stack reads as not-deployed — accepted.)
#
# Returns nonzero in all three cases; the caller skips the dump either way.
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
    # dir may exist (GitOps seeds it) but no container was ever created -> the
    # stack is registered, not deployed. Silent skip, same as no dir at all.
    log "skip: $stack is not deployed on this host (no $container container)"
    return 1
}

# Rename a finished dump into place — but only if it has content: a command
# that exits 0 having written nothing (full disk at the last write, a client
# that logs its error and still returns 0) must not rename a zero-byte file
# over the last good dump. Callers set their own rc counter from the return
# value (the VPS leg uses a different one).
#
# Cannot false-alarm on a legitimately empty database: `sqlite3 .backup` of a
# ZERO-BYTE source emits a valid 4096-byte one-page database (verified
# against sqlite 3.51), and pg_dumpall of an empty cluster still emits its
# header. Zero bytes here means something went wrong, always.
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
# pg_dumpall against the container's superuser. A logical dump is restorable;
# a file-level copy of a live pgdata directory generally is not, which is why
# the Backrest plans exclude **/pgdata/**.
#
# komodo is the manager's OWN state (Resource-Sync defs, stack registrations,
# users), not a managed stack — FerretDB stores it all as JSONB in this
# Postgres, so one pg_dumpall captures Komodo entirely. Replaces the arcane
# sqlite line removed below. Expects container komodo_db + superuser komodo
# (POSTGRES_USER), like every entry here. Komodo lives at /srv/komodo, not
# /srv/stacks/komodo, so require_running's $STACKS/<name> presence check never
# matches it: a fully-removed komodo silently skips (as arcane did before it),
# while a stopped-but-present komodo_db still FAILS loudly via the exists() branch.
for svc in paperless immich firefly dawarich tandoor wger windmill outline ghostfolio komodo excalidraw; do
    container="${svc}_db"
    # Every service in this loop is also its own stack directory name.
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
# 🚨 `mariadb-dump`, NOT `mysqldump`. MariaDB 11.x DROPPED the mysql*
# symlinks entirely — `mysqldump` in mariadb:11.8.9 fails with exit 127
# (loud, but only after deploy). Caught by tests/suites/tracking.nix, which
# runs this exact command.
#
# The ENV VAR keeps the MYSQL_ spelling: the image accepts MYSQL_ROOT_PASSWORD
# as an alias for MARIADB_ROOT_PASSWORD, and stacks/tracking/compose.yaml sets
# it that way so this line can read it from the container's environment.
#
# 🚨 MYSQL_PWD, NOT `-p"$PASSWORD"`: /proc/<pid>/cmdline is world-readable on
# the HOST (whose PID namespace is a superset of every container's), while
# /proc/<pid>/environ is owner/root-only — a real narrowing. Containers do
# NOT see each other's processes (no stack sets `pid: host`; verified by
# listing /proc inside one), so the exposure was host-local.
#
# `export` on its own line: assignment prefixes on the `exec` special builtin
# are a POSIX corner not worth relying on across busybox/dash/bash.
#
# MYSQL_PWD is honoured by BOTH clients — checked rather than assumed, per
# finding #35: the exact command below ran against the pinned mariadb:11.8.9
# and mysql:8.4.6 images, each producing a full --all-databases dump (3.2 MB
# and 3.8 MB) with no "password on the command line" warning.
#
# DocSpace's portal database. MySQL 8.4, unlike MariaDB 11, DOES still ship
# `mysqldump` — the mariadb rename does not apply here.
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

# BookStack lives in the tracking stack, so the container name and the stack
# directory name differ — the one place in this script where they do.
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
# `.backup` is safe against a live writer. Copying a WAL-mode database file
# directly is not — it can capture a torn page set with an out-of-date -wal.
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
# Mealie is SQLITE ON PURPOSE (see the compose header: its engine switch
# silently treats anything but the literal `postgres` as sqlite). The one
# live-writer file under /mnt/fast/mealie; the mealie suite runs this exact
# `.backup` and asserts the copy holds the admin row.
sqlite_backup mealie         /mnt/fast/mealie/mealie.db
# Wealthfolio (evaluation): WAL-mode, live writer — this is the restorable
# copy. secrets.json beside it is covered as a file, useful only with
# WF_SECRET_KEY from .sops.env (in git). The wealthfolio suite pins the db's
# real path: sqlite_backup returns 0 for a missing source (finding #25), so
# an upstream path move would otherwise no-op this line forever.
sqlite_backup wealthfolio    /mnt/fast/wealthfolio/wealthfolio.db
# Karakeep keeps TWO sqlite databases under DATA_DIR: the app database and a
# separate job queue (liteque, reconstructible but a few KB). Both paths are
# asserted by the tracking suite — a wrong path here once backed up nothing,
# forever, with a clean exit (sqlite_backup returns 0 for a missing source).
sqlite_backup karakeep       /mnt/fast/karakeep/data/db.db
sqlite_backup karakeep-queue /mnt/fast/karakeep/data/queue.db
sqlite_backup homebox        /mnt/fast/homebox/homebox.db
# NO uptimekuma LINE, deliberately: the stack has never been built, and a
# speculative backup line is a permanently-silent no-op — the backup-coverage
# lint fails on exactly this shape. Add it back together with the stack, not
# before. (Monitoring is moving to Gatus, config-file-only, no database — see
# ServerNotes/designs/service-monitoring-stack-research.md.)
sqlite_backup homeassistant  /mnt/fast/homeassistant/home-assistant_v2.db
# Frigate's event/review/user index (stacks/automation). WAL-mode and
# continuously written — this dump is the restorable copy. Recordings under
# /mnt/slow/frigate are deliberately not backed up at all: re-recordable, and
# the slow plan's include list omits them.
sqlite_backup frigate        /mnt/fast/frigate/config/frigate.db
sqlite_backup audiobookshelf /mnt/fast/audiobookshelf/config/absdatabase.sqlite
# Kavita's is WAL-mode by default since 0.8.2 — same torn-snapshot reason as
# the arr databases below. Both books paths (kavita, shelfmark) are asserted
# to exist by the books suite, so a layout change in a future image fails a
# test instead of silently skipping (sqlite_backup returns 0 when missing).
sqlite_backup kavita         /mnt/fast/kavita/config/kavita.db
# Shelfmark's users.db is not documented upstream but was VERIFIED from a
# books-suite run (alongside settings.json and .flask_secret in /config).
sqlite_backup shelfmark      /mnt/fast/shelfmark/config/users.db

# The arr databases are WAL-mode and written continuously (queue/history/RSS
# churn) — same torn-snapshot reason as the rest of this section. Paths follow
# the /config binds in stacks/media/compose.yaml (LSIO layout: <db>.db at the
# config root; bazarr keeps its under db/). The sibling logs.db files are
# deliberately NOT dumped — log churn, rebuilt on start, worthless in a
# restore.
sqlite_backup radarr         /mnt/fast/radarr/config/radarr.db
sqlite_backup sonarr         /mnt/fast/sonarr/config/sonarr.db
sqlite_backup prowlarr       /mnt/fast/prowlarr/config/prowlarr.db
sqlite_backup bazarr         /mnt/fast/bazarr/config/db/bazarr.db
sqlite_backup jellyfin       /mnt/fast/jellyfin/config/data/jellyfin.db
sqlite_backup jellyfin-lib   /mnt/fast/jellyfin/config/data/library.db
sqlite_backup seerr          /mnt/fast/seerr/config/db/db.sqlite3
# Cleanuparr's EF-Core sqlite lives somewhere under /mnt/fast/cleanuparr; its
# filename is UNVERIFIED (v2 is UI-configured; the DB appears at first setup)
# — raw-copy path only until the name is pinned down. All of the above paths
# are asserted to exist by the media suite.

# Beszel's hub is PocketBase, TWO databases side by side: data.db holds
# systems, users and every system_stats row — the entire metric history.
# auxiliary.db (PocketBase's own request/error log) is deliberately NOT backed
# up: regenerated, larger, worthless. Both run WAL mode — at time of writing
# data.db was 4 KB with an 853 KB -wal beside it, so a plain copy would have
# captured almost nothing; `sqlite3 .backup` is why this helper exists rather
# than a cp.
#
# Also deliberately NOT backed up: id_ed25519 and config.yml in the same
# directory — beszel-init regenerates both from stacks/beszel/.sops.env, so
# the encrypted repo is already their backup.
sqlite_backup beszel         /mnt/fast/beszel/data.db

# Forgejo — the git ROOT for this homelab. Its compose configures no
# database, so the image falls back to sqlite3 at /data/gitea/gitea.db
# (verified from the pinned image's /etc/templates/app.ini and the app.ini it
# generates), i.e. a raw copy of a live writer inside the fast plan's include
# set.
#
# Measured, not assumed: a fresh forgejo:16.0 keeps gitea.db in WAL mode with
# a -wal LARGER than the database (1.3M db, 4.1M -wal seconds after first
# start). A file copy of the live db held **73 tables**; `sqlite3 .backup` of
# the same database held **131** and passed PRAGMA integrity_check — 58
# tables missing, unrestorable in fact.
#
# Not `forgejo dump`, deliberately: that zips the repositories too, and they
# are already plain files under the same bind the fast plan backs up
# file-by-file — doubling the largest thing on the volume for nothing. Only
# the metadata database needs the SQLite treatment. app.ini (SECRET_KEY,
# INTERNAL_TOKEN, JWT secrets — self-generated on first start, none in git)
# lives beside it and is covered as a file.
sqlite_backup forgejo        /mnt/fast/forgejo/data/gitea/gitea.db

# Ntfy's user/token/ACL database (stacks/ntfy/server.yml: auth-file) — the
# alerting path's own state, nothing else reproduces it. The message cache
# (cache-file, /mnt/fast/ntfy/cache/cache.db) is deliberately NOT dumped: at
# most 168h of already-delivered notifications, worthless in a restore — same
# call as beszel's auxiliary.db above.
sqlite_backup ntfy           /mnt/fast/ntfy/lib/auth.db

# Gatus's result history (storage.type sqlite over the /mnt/fast/gatus bind).
# Endpoint definitions are config in git; only the uptime/latency history is
# here, written on every probe cycle (75 endpoints, so continuously) — same
# live-writer situation as the rest of this section.
sqlite_backup gatus          /mnt/fast/gatus/gatus.db

# Grafana's own state (stacks/logging). Its default database is sqlite at
# /var/lib/grafana/grafana.db over the /mnt/fast/grafana bind, and it is
# WAL-mode with a live writer — the same raw-copy trap as forgejo above.
#
# What is genuinely only here is small but not reproducible: dashboards, saved
# Explore queries, users, API keys and preferences. Everything else that makes
# this stack work is declared in git and re-applied on every deploy — the
# VictoriaLogs datasource comes from stacks/logging/grafana-datasource.yaml
# (provisioned read-only, `editable: false`) and the admin credential from
# stacks/logging/.sops.env — so a restore that lost this file would come back
# working, just empty of anything a human made.
#
# 🚨 VICTORIALOGS' STORE IS DELIBERATELY NOT DUMPED AND NOT BACKED UP AT ALL.
# /mnt/slow/victorialogs is on no Backrest plan and has a NOT_BACKED_UP entry
# in tests/lib/lints.nix carrying the reasoning: it is up to 100 GiB of
# observations about a fleet whose actual state lives elsewhere, and a restore
# that replays months of old logs into a rebuilt host would be actively
# misleading. This line is the whole of the logging stack's backup, on purpose.
sqlite_backup grafana        /mnt/fast/grafana/grafana.db

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
# installed at $VPS_KEY). Two unusable states, both loud via rc=1 ->
# OnFailure -> ntfy: file missing, or still the committed changeme_ template
# (a fresh deploy installs that verbatim; ssh would fail late and cryptically
# on invalid key format, so refuse up front).
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
    # derp_server_private.key here — the control-plane identity: lose the keys
    # and every client must re-authenticate.
    #
    # The database gets the SAME `.backup` treatment as every local sqlite
    # (see the forgejo note: 73 vs 131 tables from a raw copy). headscale runs
    # WAL-mode (write_ahead_log defaults to true; modules/headscale.nix sets
    # only type/path), so an rsync of the live file is the torn-copy pattern
    # this script exists to avoid. Snapshot on the VPS, pull it, exclude the
    # live files. sqlite3 is provisioned in headscale-vps/configuration.nix.
    log "headscale sqlite snapshot (via $VPS_HOST)"
    snapshot_ok=1
    if ! ssh "${ssh_opts[@]}" "$VPS_USER@$VPS_HOST" \
        'sudo sqlite3 /var/lib/headscale/db.sqlite ".backup /var/lib/headscale/db-backup.sqlite"'; then
        log "FAILED: headscale sqlite snapshot"
        snapshot_ok=0
        rc_vps=1
    fi

    # The live db.sqlite and its -wal/-shm are EXCLUDED, and the exclusion also
    # protects them from --delete on the receiver — which is what keeps the
    # previous good snapshot in place when tonight's fails, exactly as
    # finish_dump does for every local dump.
    log "headscale state pull"
    if ! rsync -a --delete \
        --exclude='db.sqlite' --exclude='db.sqlite-*' --exclude='db-backup.sqlite' \
        --rsync-path='sudo rsync' \
        -e "ssh ${ssh_opts[*]}" \
        "$VPS_USER@$VPS_HOST:/var/lib/headscale/" "$VPSDIR/headscale/"; then
        log "FAILED: headscale state pull"
        rc_vps=1
    fi

    # Lands under the live file's name: the DR path (and the tailnet suite)
    # expects _vps/headscale/db.sqlite. Pulled separately so it goes through
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

    # Sidecars left by the pre-snapshot raw pulls. A stale -wal beside a fresh
    # snapshot is worse than no wal at all, and the exclusions above mean rsync
    # will never clear them.
    rm -f "$VPSDIR/headscale/db.sqlite-wal" "$VPSDIR/headscale/db.sqlite-shm"
fi

# ---------------------------------------------------------------------------
# Success stamps
# ---------------------------------------------------------------------------
# TWO stamps, read with two different windows by backup-staleness-check in
# nixos/configuration.nix. A single stamp conflated two unrelated facts: a
# VPS blip set rc=1, skipped the stamp, and tripped the staleness alarm even
# though every local dump had worked — the nightly OnFailure already reports
# that failure, and a canary repeating it as "backups are stale" is how an
# alarm gets trained to be ignored.
#
# The exit code still aggregates: the unit must fail if anything failed, and
# the services suite pins that contract for the unusable-VPS-key case.
if [ "$rc_local" -eq 0 ]; then
    # The canary catching "the timer silently stopped firing" — a failure mode
    # that produces no failure notification. The external dead-man's switch
    # (DEADMAN_URL in stacks/backrest) covers the whole host being down.
    date -u +%s > "$DUMPS/.last-success-local"
fi

if [ "$rc_vps" -eq 0 ]; then
    date -u +%s > "$DUMPS/.last-success-vps"
fi

# The single stamp this pair replaces — removed because a stamp nothing
# writes or reads is exactly the artifact someone checks during an incident.
rm -f "$DUMPS/.last-success"

rc=0
if [ "$rc_local" -ne 0 ] || [ "$rc_vps" -ne 0 ]; then
    rc=1
    log "completed WITH FAILURES (local=$rc_local vps=$rc_vps)"
else
    log "complete"
fi
exit "$rc"
