#!/usr/bin/with-contenv bash
# bookstack-admin-init — replaces BookStack's seeded admin, from INSIDE the
# bookstack container (annex §3).
#
# Why here rather than an init container: BookStack's initial migration
# seeds `admin@admin.com` / `password` (no env override), its REST API needs
# a UI-minted token, and the only tool is an artisan command — so something
# must run inside this container. The alternatives were worse: a
# socket-mounting oneshot widens socket access (the exact thing
# keep-decryption-on-the-host exists to avoid), and a host-side `docker
# exec` unit puts a piece of this stack outside the deploy plane.
#
# LSIO runs every script in /custom-cont-init.d as root during s6 init,
# before the app — documented extension point, no socket, ships with the
# stack. `with-contenv` gives it the container's environment.
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

# On a truly fresh volume there may be no users table yet — the command
# fails harmlessly and the next boot picks it up. Deliberately not retried
# in a loop: s6 init blocking on a database is how a container never starts.
#
# ACCEPTED argv exposure: --password= is visible in /proc/<pid>/cmdline
# (world-readable in the host PID namespace) while this runs.
# create-admin takes the password only as a CLI option — no env var, no
# file — and its fallback prompt needs a TTY s6 init does not give it.
# ServerNotes/issues/code-review-2026-08-31.md, "Accepted".
#
# Captured rather than piped through sed in the `if`: without pipefail the
# pipeline's status is sed's (always 0) — CHANGE logged every boot, exit-2
# branch unreachable. Capturing also tells exit 2 from a real failure.
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
