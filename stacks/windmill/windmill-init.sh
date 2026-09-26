#!/bin/sh
# Headless first-run for Windmill (annex §3.4). Upstream's documented setup is
# "log in as admin@windmill.dev / changeme, then use the UI" with no forced
# password change, so the published default is live until a human intervenes.
# SUPERADMIN_SECRET presented as a bearer token authenticates against the
# ordinary API without ever using `changeme`.
#
# Roster: idan is the super_admin, the other six are regular instance users
# (tier-2b local accounts — only SSO federation is Enterprise, see
# login-tiers.md). Each password is a copy_only twin of that user's Authentik
# password, so one memorable password covers Authentik, Windmill and Samba.
#
# Every mutation logs "windmill-init: CHANGE: ...". A second run — every
# redeploy reruns this container — must log ZERO change lines.
set -eu

python3 - <<'PY'
import json
import os
import sys
import time
import urllib.error
import urllib.request

WM = "http://windmill_server:8000"
DEFAULT_ADMIN = "admin@windmill.dev"

# (email, password_env, super_admin). A create is a no-op for an existing
# account, so an already-provisioned user keeps whatever password they have.
USERS = [
    ("idan@idanreed.com",               "IDAN_INITIAL_PASSWORD",    True),
    ("apcalondraperezcortez@gmail.com", "ALONDRA_INITIAL_PASSWORD", False),
    ("calethim@gmail.com",              "CALE_INITIAL_PASSWORD",    False),
    ("zach@hayzak.com",                 "ZACH_INITIAL_PASSWORD",    False),
    ("rylankasitz@gmail.com",           "RYLAN_INITIAL_PASSWORD",   False),
    ("camos3434@gmail.com",             "CAMERON_INITIAL_PASSWORD", False),
    ("justindanita@gmail.com",          "JUSTIN_INITIAL_PASSWORD",  False),
]


def log(msg):
    print(f"windmill-init: {msg}", flush=True)


def fatal(msg):
    print(f"windmill-init: FATAL: {msg}", flush=True)
    sys.exit(1)


def env(name):
    v = os.environ.get(name, "").strip()
    if not v:
        # Unset means the .env did not decrypt, and "unprovisioned" means
        # admin@windmill.dev / changeme stays live on a service that runs
        # arbitrary code.
        fatal(f"{name} is unset or empty")
    return v


def request(url, *, method="GET", body=None, token=None, timeout=30):
    data = None
    headers = {}
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read().decode().strip()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode().strip()


def wait_for_server(tries=90, delay=2):
    for _ in range(tries):
        try:
            code, _ = request(f"{WM}/api/health/status", timeout=5)
            if code < 500:
                return
        except Exception:
            pass
        time.sleep(delay)
    fatal("windmill never answered /api/health/status")


secret = env("SUPERADMIN_SECRET")
workspace = os.environ.get("WINDMILL_WORKSPACE", "main").strip() or "main"

# Resolve passwords up front so a missing/short one fails before any mutation.
roster = []
for email, pw_env, is_super in USERS:
    email = email.lower()
    if email == DEFAULT_ADMIN:
        fatal(f"roster email must not be {DEFAULT_ADMIN}")
    pw = env(pw_env)
    if len(pw) < 12:
        fatal(f"{pw_env} must be at least 12 characters")
    roster.append((email, pw, is_super))

wait_for_server()

# Every admin operation below uses the SUPERADMIN_SECRET bearer, never a
# login-as-a-user session — which also sidesteps a 401 when a stored password
# differs from the account's real one.

# Users — idempotent, 400 "already exists" is a no-op
for email, pw, is_super in roster:
    code, body = request(
        f"{WM}/api/users/create",
        method="POST",
        body={"email": email, "password": pw, "super_admin": is_super},
        token=secret,
    )
    if code < 300:
        log(f"CHANGE: created {'superadmin' if is_super else 'user'} {email}")
    elif code == 400 and "already exists" in body.lower():
        log(f"{email} already exists")
    else:
        # 401/403 means SUPERADMIN_SECRET is not being accepted — the difference
        # between "provisioned" and "changeme is still live". Never swallow it.
        fatal(f"POST /api/users/create ({email}) returned {code}: {body[:400]}")

# Workspace
code, body = request(f"{WM}/api/workspaces/list", token=secret)
existing = set()
if code < 300 and body:
    try:
        existing = {w["id"] for w in json.loads(body)}
    except (ValueError, KeyError, TypeError):
        existing = set()

if workspace in existing:
    log(f"workspace '{workspace}' already exists")
else:
    # ⚠ `username` is REJECTED on this version:
    #     400 Bad request: username is not allowed when username creation is
    #     automated
    # Older Windmill required it, newer derives it. Send the minimal body and
    # add `username` back only if the server asks for it, so this works either
    # way rather than pinning to whichever behaviour today's image has.
    payload = {"id": workspace, "name": workspace}
    code, body = request(
        f"{WM}/api/workspaces/create", method="POST", body=payload, token=secret
    )
    if code == 400 and "username" in body.lower() and "not allowed" not in body.lower():
        payload["username"] = "idan"
        code, body = request(
            f"{WM}/api/workspaces/create", method="POST", body=payload, token=secret
        )

    if code < 300:
        log(f"CHANGE: created workspace '{workspace}'")
    elif code == 400 and "already exists" in body.lower():
        log(f"workspace '{workspace}' already exists")
    else:
        fatal(f"POST /api/workspaces/create returned {code}: {body[:400]}")

# Workspace membership — BEST-EFFORT
# The instance accounts above are what let people log in; membership is a
# convenience on top, and this endpoint is version-sensitive (add vs invite,
# body shape), so a non-2xx is a WARNING and never fatal.
for email, _, is_super in roster:
    if is_super:
        continue  # superadmins already have access to every workspace
    code, body = request(
        f"{WM}/api/w/{workspace}/workspaces/add_user",
        method="POST",
        body={"email": email, "is_admin": False, "operator": False},
        token=secret,
    )
    low = body.lower()
    if code < 300:
        log(f"CHANGE: added {email} to workspace '{workspace}'")
    elif code == 400 and "already" in low:
        log(f"{email} already in workspace '{workspace}'")
    else:
        log(
            f"WARN: could not add {email} to workspace '{workspace}' "
            f"({code}: {body[:200]}); the account still exists — add it in the "
            f"UI if workspace membership is wanted"
        )

# Retire the default account
# ⚠ The verb is DELETE — a POST to the same path 405s, an easy way to "retire"
# an account that is still live.
# 🚨 The DELETE answers 2xx whether or not the account existed, so deleting
# unconditionally and logging CHANGE would print a change line EVERY run. Look
# first; claim a change only when there was one.
def default_admin_exists():
    """None when the answer cannot be determined."""
    code, body = request(
        f"{WM}/api/users/list_as_super_admin?per_page=1000", token=secret
    )
    if code >= 300 or not body:
        return None
    try:
        return any(
            (u.get("email") or "").lower() == DEFAULT_ADMIN
            for u in json.loads(body)
        )
    except (ValueError, AttributeError, TypeError):
        return None


present = default_admin_exists()

if present is False:
    log(f"{DEFAULT_ADMIN} already gone")
else:
    code, body = request(
        f"{WM}/api/users/delete/{DEFAULT_ADMIN}", method="DELETE", token=secret
    )
    if code >= 300 and code not in (404, 400):
        fatal(
            f"DELETE /api/users/delete/{DEFAULT_ADMIN} returned {code}: "
            f"{body[:400]}"
        )
    if present is True:
        log(f"CHANGE: deleted the default {DEFAULT_ADMIN} account")
    else:
        # The delete was issued blind, so say so: a wrong CHANGE line breaks the
        # "a second run prints none" contract.
        log(
            f"delete requested for {DEFAULT_ADMIN}; could not determine "
            f"whether it existed (user list unavailable)"
        )

log("done")
PY
