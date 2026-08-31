# Headless first-run for Wger (annex §3.2).
#
# Fed to `manage.py shell` on stdin, so this is a Django shell script — the ORM
# and settings are already loaded. DJANGO_SETTINGS_MODULE=settings.main and
# PYTHONPATH=/home/wger/src are baked into the image, so the container needs
# nothing but the env_file.
#
# WHY IT EXISTS: Wger creates an admin account FOR you and does not let you
# choose its password. The entrypoint runs `wger bootstrap`, which on a fresh
# database calls `create_or_reset_admin` — a `loaddata` of
# wger/core/fixtures/users.json pinning pk 1, username `admin`, is_staff true,
# **is_superuser FALSE**, and the literal pbkdf2 hash for `adminadmin`. Its own
# log line is:
#     *** Password for user admin was reset to 'adminadmin'
# There is no env var for it. Not DJANGO_SUPERUSER_*, not anything. And
# `load_fixtures` loads the same users.json in the same fresh-database branch,
# so blocking only `create_or_reset_admin` would achieve nothing.
#
# The API is not an option either: password changes go through
# allauth.headless and need an authenticated session, and the DRF user
# endpoints are read-only.
#
# Every mutation prints "wger-init: CHANGE: ...". A second run — and every
# Arcane redeploy reruns this container — must print ZERO change lines.

import os
import sys

from django.contrib.auth import get_user_model
from django.contrib.auth.hashers import check_password


def log(msg):
    print(f"wger-init: {msg}", flush=True)


def fatal(msg):
    print(f"wger-init: FATAL: {msg}", flush=True)
    sys.exit(1)


password = os.environ.get("WGER_ADMIN_PASSWORD", "").strip()
if not password:
    # Fail loudly rather than leaving `adminadmin` live. An unset value here
    # means the .env did not decrypt.
    fatal("WGER_ADMIN_PASSWORD is unset or empty")
if len(password) < 12:
    fatal("WGER_ADMIN_PASSWORD must be at least 12 characters")
if password == "adminadmin":
    fatal("WGER_ADMIN_PASSWORD is the published default")

User = get_user_model()
admin = User.objects.filter(username="admin").first()

if admin is None:
    # bootstrap did not run, which means the schema already existed when this
    # container first started. Create the account rather than assuming.
    admin = User.objects.create_superuser(
        username="admin", email="", password=password
    )
    log("CHANGE: created superuser admin")
else:
    changed = []

    # ⚠ Compare BEFORE setting. set_password() always produces a different hash
    # (new salt), so writing unconditionally and then reporting a change would
    # print a CHANGE line on every single redeploy and destroy the idempotency
    # contract every other init in this fleet is held to.
    if not check_password(password, admin.password):
        admin.set_password(password)
        changed.append("password")

    # The fixture leaves the account is_staff but NOT is_superuser, which means
    # it can reach /django-admin/ and do almost nothing there. That surprises
    # people the first time they try to configure anything.
    if not admin.is_superuser:
        admin.is_superuser = True
        changed.append("is_superuser")
    if not admin.is_staff:
        admin.is_staff = True
        changed.append("is_staff")

    if changed:
        admin.save()
        log(f"CHANGE: admin updated: {', '.join(changed)}")
    else:
        log("admin already provisioned")

# Post-condition, asserted here as well as in the suite: the published default
# must not authenticate. If a future upstream change re-runs
# create_or_reset_admin on a non-fresh database, this is where it surfaces.
admin.refresh_from_db()
if check_password("adminadmin", admin.password):
    fatal("admin still accepts the published default password 'adminadmin'")

log("done")
