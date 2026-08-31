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
# Every output is written to a .tmp and renamed only on success AND only when
# it has content, so a failed dump never silently replaces the last good one
# with a truncated — or empty — file.
#
# Note: no `set -e`. One failing service must not skip the rest; failures are
# accumulated and reported via the exit code, which trips OnFailure -> Ntfy.

set -uo pipefail

DUMPS=/mnt/fast/_dumps
VPSDIR=/mnt/fast/_vps
VPS_HOST="${VPS_HOST:-headscale-vps.tailnet.idanreed.com}"
VPS_USER="${VPS_USER:-idan}"
VPS_KEY="${VPS_KEY:-/var/lib/backup/vps_ed25519}"

# Where Arcane's git sync lands the stacks. Presence of a directory here is
# this script's only evidence that a stack is SUPPOSED to be running on this
# host — see require_running below.
STACKS="${STACKS:-/srv/stacks}"

# Escape hatch, space-separated, matched against either the stack name or the
# container name: a stack that is deliberately stopped (mid-migration, being
# retired) would otherwise page every night. Deliberately an env var on the
# unit rather than a file in the stack directory, because Arcane's git sync
# owns the contents of $STACKS and would overwrite a marker dropped there.
BACKUP_SKIP="${BACKUP_SKIP:-}"

# Two counters, not one. The exit code still aggregates them — the unit must
# fail if anything failed — but the success STAMPS are written separately, so
# a VPS the host cannot even reach does not suppress the stamp that certifies
# every local database dump. See the stamp block at the bottom.
rc_local=0
rc_vps=0

log() { echo "[backup-prepare] $*"; }

install -d -m 0700 "$DUMPS" "$VPSDIR"

running() { docker ps --format '{{.Names}}' | grep -qx "$1"; }
exists()  { docker ps -a --format '{{.Names}}' | grep -qx "$1"; }

# Is this database container expected to be running right now?
#
# This used to be a bare `running "$container" || continue`, which skipped
# without touching rc — so a stopped, crash-looping or never-deployed database
# was simply absent from the backup and the run still reported success. That is
# the same failure shape as a healthcheck that lies: green, and storing
# nothing. Three states have to be told apart, because only one of them is
# fine:
#
#   not deployed  no stack directory under $STACKS and no container of that
#                 name at all. The dump list legitimately runs ahead of the
#                 build-out (the backup-coverage lint WARNs about exactly
#                 this), so this is a silent, successful skip.
#   skipped       named in BACKUP_SKIP. Logged, not alerted.
#   expected      the stack is on disk, or a container of that name exists but
#                 is not running. That is a real hole in tonight's backup:
#                 rc_local=1, which trips OnFailure -> notify-failure@ -> ntfy
#                 exactly like a dump that errored.
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
    elif [ -d "$STACKS/$stack" ]; then
        log "FAILED: $STACKS/$stack is deployed but $container is not running - $stack has no dump in this backup"
    else
        log "skip: $stack is not deployed on this host (no $STACKS/$stack, no $container)"
        return 1
    fi
    log "  if $stack is deliberately stopped, add it to BACKUP_SKIP= on backup-prepare.service"
    rc_local=1
    return 1
}

# Rename a finished dump into place — but only if it has content.
#
# There was no size check anywhere: a command that exited 0 having written
# nothing (a full disk hit at the last write, a client that logged its error to
# stderr and still returned 0) renamed a zero-byte file over the last good
# dump. The restore drill asserts size > 0; production did not. Callers set
# their own rc counter from the return value, because the VPS leg needs a
# different one from the local legs.
#
# It cannot false-alarm on a legitimately empty database, which was the one
# thing worth checking before adding it: `sqlite3 .backup` of a ZERO-BYTE
# source emits a valid 4096-byte one-page database, never a zero-byte file
# (verified against sqlite 3.51), and pg_dumpall of an empty cluster still
# emits its header. Zero bytes here means something went wrong, always.
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
for svc in paperless immich firefly dawarich tandoor wger windmill; do
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
#
# 🚨 MYSQL_PWD, NOT `-p"$PASSWORD"`. Both branches used to interpolate the
# password into argv, and /proc/<pid>/cmdline is world-readable — on the HOST,
# where every container's processes are visible (the host PID namespace is a
# superset of every container's; `ps -eo args` shows `mariadbd` and `mysqld`
# by name). /proc/<pid>/environ is readable only by the process owner and
# root, so moving the secret from argv to the environment is a real narrowing
# even though nothing here is reachable by an untrusted account.
#
# Note what the argv exposure was NOT: containers do not see each other's
# processes. No stack in this fleet sets `pid: host`, and a plain container
# gets its own PID namespace — verified by listing /proc from inside one
# (only its own PID 1 and the exec'd shell are there). The exposure is
# host-local, which is why this is a narrowing and not an incident.
#
# `export`ed on its own line rather than as a `VAR=val exec cmd` prefix:
# assignment prefixes on the `exec` special builtin are a corner of POSIX not
# worth relying on across busybox/dash/bash entrypoint shells.
#
# MYSQL_PWD is honoured by BOTH clients, which was worth checking rather than
# assuming given finding #35: the exact command below was run against the
# pinned mariadb:11.8.9 and mysql:8.4.6 images and each produced a full
# --all-databases dump (3.2 MB and 3.8 MB), with no "password on the command
# line" warning. A client that ignored it would prompt for a password on a
# non-tty and fail loudly, not dump nothing — but loud only helps after
# deploy, which is the lesson finding #35 already paid for.
#
# DocSpace's portal database (stacks/docspace/compose.yaml). MySQL 8.4, which
# unlike MariaDB 11 DOES still ship `mysqldump` — the rename that broke the
# BookStack branch below was specifically MariaDB dropping its mysql* symlinks,
# and it does not apply here.
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

# Forgejo — the git ROOT for this homelab, and until now the only stack whose
# database was in no dump at all. stacks/forgejo/compose.yaml configures no
# database, so the image falls back to its sqlite3 default at
# /data/gitea/gitea.db (verified from the pinned image's /etc/templates/app.ini
# and from the app.ini it generates: DB_TYPE = sqlite3, PATH =
# /data/gitea/gitea.db), and /data is the /mnt/fast/forgejo/data bind. That put
# the file inside the fast plan's include set as a RAW COPY taken while Forgejo
# was writing it, which is not a restorable database.
#
# Measured, not assumed. A freshly started forgejo:16.0 keeps gitea.db in WAL
# mode (PRAGMA journal_mode -> wal) with a -wal LARGER THAN THE DATABASE: 1.3M
# db beside a 4.1M -wal, seconds after first start. Copying the file alone and
# querying the copy finds **73 tables**; `sqlite3 .backup` of the same live
# database finds **131**, and passes PRAGMA integrity_check. The file-level
# backup of this fleet's git server was missing 58 tables — not torn in
# theory, unrestorable in fact. Same shape as the beszel note above (4 KB db,
# 853 KB -wal), one order of magnitude worse.
#
# Not `forgejo dump` — deliberately. That produces a zip of the repositories,
# the database, the config and the attachments in one artifact, and the
# repositories are already plain files under the same bind that the fast plan
# backs up file-by-file. Dumping them a second time inside a zip would double
# the largest thing on the volume to gain nothing; only the metadata database
# needs the SQLite treatment, and this is it. app.ini (SECRET_KEY,
# INTERNAL_TOKEN, the JWT secrets — all self-generated on first start, none of
# them in git) lives beside it in the same bind and is covered as a file.
sqlite_backup forgejo        /mnt/fast/forgejo/data/gitea/gitea.db

# Ntfy's user/token/ACL database (stacks/ntfy/server.yml: auth-file). Small,
# and the alerting path's own state — nothing else in the fleet reproduces it.
#
# Its sibling, the message cache (cache-file, /mnt/fast/ntfy/cache/cache.db),
# is deliberately NOT dumped: it holds at most cache-duration 168h of
# already-delivered notifications, it is the larger of the two, and it is
# worthless in a restore. Same call as beszel's auxiliary.db above.
sqlite_backup ntfy           /mnt/fast/ntfy/lib/auth.db

# Gatus's result history (stacks/gatus/gatus.yaml: storage.type sqlite,
# storage.path /data/gatus.db over the /mnt/fast/gatus bind). The endpoint
# definitions are config and live in git; what is only here is the uptime and
# latency history, which is the entire point of running a prober rather than
# looking at a dashboard. Written on every probe cycle (75 endpoints, so
# continuously), which is the same live-writer situation as the rest of this
# section — the raw file in the include set is a torn snapshot and this is the
# restorable copy.
sqlite_backup gatus          /mnt/fast/gatus/gatus.db

# Arcane's own state — the GitOps sync definitions, i.e. the thing that knows
# how every stack on this host is delivered. It lived in the `arcane_data`
# NAMED volume until 2026-08-31, which put it under /var/lib/docker and
# therefore inside the Backrest plans' `**/docker/**` exclusion: it was in no
# backup at all. arcane/compose.yaml now binds /mnt/fast/arcane to /app/data
# (the image declares VOLUME /app/data and its DATABASE_URL default is
# `file:data/arcane.db`), so the file is finally reachable — and, being WAL,
# needs the same `.backup` treatment as forgejo rather than a raw copy.
#
# Why it matters more than its size suggests: `syncDirectory` is a per-sync
# flag that defaults OFF in v1.17.4, so a sync definition recreated by hand
# after a restore silently reverts to single-file mode and stops delivering
# the sibling .sops.env — a restore that looks fine and ships no secrets.
sqlite_backup arcane         /mnt/fast/arcane/arcane.db

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
    # derp_server_private.key here. The keys are the control-plane identity:
    # lose them and every client must re-authenticate.
    log "headscale state pull"
    if ! rsync -a --delete \
        --rsync-path='sudo rsync' \
        -e "ssh ${ssh_opts[*]}" \
        "$VPS_USER@$VPS_HOST:/var/lib/headscale/" "$VPSDIR/headscale/"; then
        log "FAILED: headscale state pull"
        rc_vps=1
    fi
fi

# ---------------------------------------------------------------------------
# Success stamps
# ---------------------------------------------------------------------------
# TWO stamps, read with two different windows by backup-staleness-check in
# nixos/configuration.nix. They were one, and that conflated two unrelated
# facts: a VPS pull failure — a tailnet blip, a VPS that is rebooting — set
# rc=1, which skipped the single stamp, which tripped the staleness alarm the
# next day even though every local database dump had worked. The nightly
# OnFailure notification ALREADY reports that specific failure; the staleness
# canary firing about it too, in the language of "backups are stale", is how
# an alarm gets trained to be ignored.
#
# The exit code still aggregates: the unit must fail if anything failed, and
# the services suite pins that contract for the unusable-VPS-key case.
if [ "$rc_local" -eq 0 ]; then
    # The canary that catches "the timer silently stopped firing" — a failure
    # mode that by definition produces no failure notification. The external
    # dead-man's switch (DEADMAN_URL in stacks/backrest) covers the case where
    # this whole host is down.
    date -u +%s > "$DUMPS/.last-success-local"
fi

if [ "$rc_vps" -eq 0 ]; then
    date -u +%s > "$DUMPS/.last-success-vps"
fi

# Migration: the single stamp this pair replaces. Removed rather than left
# behind, because a file named .last-success that nothing writes and nothing
# reads is exactly the artifact someone checks during an incident.
rm -f "$DUMPS/.last-success"

rc=0
if [ "$rc_local" -ne 0 ] || [ "$rc_vps" -ne 0 ]; then
    rc=1
    log "completed WITH FAILURES (local=$rc_local vps=$rc_vps)"
else
    log "complete"
fi
exit "$rc"
