#!/usr/bin/with-contenv bash
# bookstack-admin-init — replaces BookStack's seeded admin, from INSIDE the
# bookstack container (annex §3).
#
# Why it lives here rather than in an init container:
#
# BookStack is the only service in this domain with no HTTP path to a first
# admin. Its initial migration seeds `admin@admin.com` / `password` with no
# env var to change it, and its REST API needs a token that can only be minted
# through the UI. The only tool is an artisan command — which means running
# something inside this container.
#
# The obvious options were both worse. A oneshot with the docker socket
# mounted would add a SECOND socket-mounting container to the fleet, and
# keeping the age key out of the one container that mounts the socket is
# exactly why CLAUDE.md puts decryption on the host — widening socket access
# to save a unit is a bad trade. A host-side systemd unit doing `docker exec`
# works, but puts a piece of this stack outside the stack, where Arcane cannot
# deploy it.
#
# LSIO images run every script in /custom-cont-init.d as root during s6 init,
# before the application starts. That is a documented, supported extension
# point, it needs no socket, and it ships with the stack. `with-contenv` in
# the shebang is what gives the script the container's environment.
#
# Contract:
#   - `--initial` is what makes this idempotent: it UPDATES the seeded admin
#     in place, and warns-and-no-ops if a real admin already exists. WITHOUT
#     it the command blocks on an interactive prompt — a hang, not an error,
#     which in s6 init means the container never finishes starting.
#   - Unset credentials are NOT fatal here. This runs before the app, and
#     failing the boot over a missing optional secret would take the wiki
#     down; the seeded admin remains and the log says so loudly.
set -u

log() { echo "[bookstack-admin-init] $*"; }

if [ -z "${BOOKSTACK_ADMIN_EMAIL:-}" ] || [ -z "${BOOKSTACK_ADMIN_PASSWORD:-}" ]; then
    log "BOOKSTACK_ADMIN_EMAIL/PASSWORD not set — LEAVING THE SEEDED ADMIN IN"
    log "PLACE (admin@admin.com / password). Set them in .sops.env."
    exit 0
fi

case "$BOOKSTACK_ADMIN_PASSWORD" in
    changeme_*)
        log "BOOKSTACK_ADMIN_PASSWORD is still the .sops.env.example"
        log "placeholder — refusing to set it. The seeded admin stays."
        exit 0
        ;;
esac

# The app root is fixed by the image layout.
cd /app/www || { log "FATAL: /app/www missing — image layout changed"; exit 0; }

# Migrations have not necessarily run on a truly fresh volume, in which case
# there is no users table yet and the command fails harmlessly; the next boot
# picks it up. Deliberately not retried in a loop: s6 init blocking on a
# database is how a container never starts.
#
# Captured rather than piped through sed in the `if`: without pipefail the
# pipeline's status is sed's (always 0), which logged CHANGE on every boot
# and made the exit-2 branch unreachable. Capturing also lets exit 2 be told
# apart from a real failure.
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
