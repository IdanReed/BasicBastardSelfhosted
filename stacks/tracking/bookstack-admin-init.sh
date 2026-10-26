#!/usr/bin/with-contenv bash
# bookstack-admin-init — replaces BookStack's seeded admin, from INSIDE the
# bookstack container. LSIO runs every script in /custom-cont-init.d as root
# during s6 init, before the app.
#
# Here rather than an init container because the only tool is an artisan
# command: a socket-mounting oneshot would widen socket access, and a
# host-side `docker exec` unit would put part of this stack outside the deploy
# plane.
#
# Contract:
#   - `--initial` is what makes this idempotent: it updates the seeded admin
#     in place and no-ops if a real one exists. WITHOUT it the command blocks
#     on an interactive prompt, which in s6 init means the container never
#     finishes starting.
#   - Unset credentials are NOT fatal: this runs before the app, and failing
#     the boot over a missing optional secret would take the wiki down.
set -u

log() { echo "[bookstack-admin-init] $*"; }

if [ -z "${BOOKSTACK_ADMIN_EMAIL:-}" ] || [ -z "${BOOKSTACK_ADMIN_PASSWORD:-}" ]; then
    log "BOOKSTACK_ADMIN_EMAIL/PASSWORD not set — LEAVING THE SEEDED ADMIN IN"
    log "PLACE (admin@admin.com / password). Set them in secrets.sops.json."
    exit 0
fi

case "$BOOKSTACK_ADMIN_PASSWORD" in
    changeme_*)
        log "BOOKSTACK_ADMIN_PASSWORD is still the secrets.example.env"
        log "placeholder — refusing to set it. The seeded admin stays."
        exit 0
        ;;
esac

# The app root is fixed by the image layout.
cd /app/www || { log "FATAL: /app/www missing — image layout changed"; exit 0; }

# On a fresh volume there may be no users table yet; the command fails
# harmlessly and the next boot picks it up. Deliberately not retried in a
# loop — s6 init blocking on a database is how a container never starts.
#
# 🚨 ACCEPTED argv exposure: --password= is visible in /proc/<pid>/cmdline
# while this runs. create-admin takes the password only as a CLI option (no
# env var, no file) and its fallback prompt needs a TTY s6 init cannot give.
#
# Captured rather than piped through sed inside the `if`: without pipefail the
# pipeline's status would be sed's, i.e. always 0.
out=$(php artisan bookstack:create-admin \
        --initial \
        --email="$BOOKSTACK_ADMIN_EMAIL" \
        --name="${BOOKSTACK_ADMIN_NAME:-Admin}" \
        --password="$BOOKSTACK_ADMIN_PASSWORD" 2>&1)
rc=$?
printf '%s\n' "$out" | sed 's/^/[bookstack-admin-init] /'
if [ "$rc" -eq 0 ]; then
    log "CHANGE: admin set to $BOOKSTACK_ADMIN_EMAIL"
elif [ "$rc" -eq 2 ]; then
    # Exit 2 is the documented "a real admin already exists" case, which is
    # the steady state after the first boot — not an error.
    log "create-admin did not apply (already provisioned) - no change"
else
    # Fresh-volume case (database not migrated yet) or a real failure. Either
    # way the seeded admin is still live — say so loudly, but do not block
    # the boot (see the contract above); the next boot retries.
    log "ERROR: create-admin failed (rc=$rc) — the seeded admin"
    log "(admin@admin.com / password) is still in place - no change"
fi

exit 0
