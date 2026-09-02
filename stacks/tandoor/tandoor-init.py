# Headless first-run for Tandoor (annex §3.1).
#
# Fed to `manage.py shell` on stdin, so this file is a Django shell script, not
# a standalone program — the ORM and settings are already loaded when it runs.
#
# WHY IT EXISTS: Tandoor has no env-var and no REST path to a first
# superuser — `/setup/` is a browser form that refuses once any user exists,
# and there is no management command for it.
#
# ⚠ NOT `seed_basic_data`: it looks exactly like the tool for this job but
# is a DEVELOPER FIXTURE — user `test` with password 'test' and a "Test
# Space".
#
# Every mutation prints "tandoor-init: CHANGE: ...". A second run — every
# redeploy reruns this container — must print ZERO change lines.

import os
import sys

from django.contrib.auth import get_user_model
from django_scopes import scopes_disabled

from cookbook.helper.permission_helper import create_space_for_user


def log(msg):
    print(f"tandoor-init: {msg}", flush=True)


def fatal(msg):
    print(f"tandoor-init: FATAL: {msg}", flush=True)
    sys.exit(1)


def env(name):
    v = os.environ.get(name, "").strip()
    if not v:
        # Fail loudly: unset means the .env did not decrypt, and an
        # unprovisioned Tandoor serves /setup/ to whoever reaches it first.
        fatal(f"{name} is unset or empty")
    return v


username = env("TANDOOR_ADMIN_USER")
email = env("TANDOOR_ADMIN_EMAIL")
password = env("TANDOOR_ADMIN_PASSWORD")

if len(password) < 12:
    fatal("TANDOOR_ADMIN_PASSWORD must be at least 12 characters")
if username == "test":
    fatal("TANDOOR_ADMIN_USER must not be 'test' — that is seed_basic_data's "
          "developer fixture account")

User = get_user_model()

# 🚨 EVERY ORM STATEMENT MUST BE INSIDE scopes_disabled(). Tandoor uses
# django-scopes, and a bare query against a scoped model RAISES rather than
# quietly returning the wrong rows — which is the good failure mode, but only
# if you know to expect it. `create_space_for_user` and the `/setup/` view are
# both already wrapped, so this nesting is harmless.
with scopes_disabled():
    user = User.objects.filter(username=username).first()

    if user is None:
        user = User.objects.create_user(
            username=username, email=email, password=password
        )
        # The /setup/ view sets BOTH of these, so an ORM-created user must too.
        user.is_superuser = True
        user.is_staff = True
        user.save()
        log(f"CHANGE: created superuser {username}")
    else:
        log(f"superuser {username} already exists")
        # Idempotent repair, not a reset: never touch the password of an
        # existing account here, or every redeploy would clobber a password the
        # operator changed in the UI.
        changed = []
        if not user.is_superuser:
            user.is_superuser = True
            changed.append("is_superuser")
        if not user.is_staff:
            user.is_staff = True
            changed.append("is_staff")
        if changed:
            user.save()
            log(f"CHANGE: repaired {username}: {', '.join(changed)}")

    # The Space: at 2.6.13 ScopeMiddleware materialises one on the first
    # authenticated request. Calling the app's OWN create_space_for_user
    # instead makes post-deploy state assertable without driving a login,
    # and (same function the middleware calls) cannot drift from upstream.
    if not user.userspace_set.filter(active=True).exists():
        create_space_for_user(user)
        log(f"CHANGE: created the space for {username}")
    else:
        log(f"{username} already has an active space")

log("done")
