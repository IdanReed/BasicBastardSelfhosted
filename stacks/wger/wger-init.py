# Headless first-run for Wger. Fed to `manage.py shell` on stdin, so the ORM
# and settings are already loaded.
#
# It exists because `wger bootstrap` loaddata's a users.json carrying username
# `admin`, is_staff true, is_superuser FALSE and the published `adminadmin`
# hash, with no env var to change any of it and no API path either (password
# changes need an authenticated allauth session).
#
# Every mutation prints "wger-init: CHANGE: ...". A second run must print
# ZERO change lines.

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

    # ⚠ Compare BEFORE setting: set_password() re-salts, so an unconditional
    # write would print a CHANGE line on every redeploy.
    if not check_password(password, admin.password):
        admin.set_password(password)
        changed.append("password")

    # The fixture leaves the account is_staff but NOT is_superuser, so it can
    # reach /django-admin/ and do almost nothing there.
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

# Post-condition: the published default must not authenticate. If a future
# upstream re-runs create_or_reset_admin on a non-fresh database, it surfaces
# here.
admin.refresh_from_db()
if check_password("adminadmin", admin.password):
    fatal("admin still accepts the published default password 'adminadmin'")

log("done")
