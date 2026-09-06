#!/bin/sh
# Headless first-run for Windmill (annex §3.4).
#
# WHY THIS EXISTS: upstream's documented setup is "log in as
# admin@windmill.dev / changeme, then use the UI" — no forced password
# change, so the published default is live until a human intervenes.
# SUPERADMIN_SECRET is the way out (the binary's --help: "virtual superadmin
# token"): presented as a bearer token it authenticates against the ordinary
# API without ever using `changeme`.
#
# ROSTER (rollout 2026-09-05): idan is the super_admin; the other 6 are regular
# instance users (tier-2b "declarative user accounts"). Each password arrives
# from .env as <USER>_INITIAL_PASSWORD — a copy_only twin of that user's
# Authentik password (secrets-gen/manifest.yaml user/*), so one memorable
# password is their login for Authentik + Windmill + Samba. Multi-user +
# workspaces are OSS; only SSO federation is Enterprise (login-tiers.md), which
# is why these are local accounts + a second login.
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

# (email, password_env, super_admin). idan is the super_admin; the 6 friends
# are regular users. Every password arrives from .env as <USER>_INITIAL_PASSWORD
# — a copy_only twin of that user's one memorable password (secrets-gen manifest
# user/*), so idan's windmill login is the SAME password as Authentik/Samba/etc.
# All admin ops below use the SUPERADMIN_SECRET bearer (never a login-as-user),
# so this stays correct even when idan's stored password differs (a create is a
# no-op for an existing account — on the current instance idan keeps whatever
# password his account already has until windmill_data is reset or he changes it
# in the UI; a fresh windmill gets IDAN_INITIAL_PASSWORD at creation).
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
        # Fail loudly: unset means the .env did not decrypt or the password was
        # never hand-set, and "unprovisioned" means admin@windmill.dev /
        # changeme stays live on a service that runs arbitrary code.
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

# All admin operations use the SUPERADMIN_SECRET bearer directly — no
# login-as-a-user session. idan is managed out of band (already superadmin),
# and a friend's own session is not needed to create them or add them to the
# workspace. This also sidesteps the "log in as idan" 401 when idan's real
# password differs from any sops value.
token = secret

# ---------------------------------------------------------------------------
# 1. Create the friend users (idempotent — 400 "already exists" is a no-op)
# ---------------------------------------------------------------------------
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
        # 401/403 here means SUPERADMIN_SECRET is not being accepted, which is
        # the difference between "provisioned" and "changeme is still live".
        # Never swallow it.
        fatal(f"POST /api/users/create ({email}) returned {code}: {body[:400]}")

# ---------------------------------------------------------------------------
# 3. The workspace
# ---------------------------------------------------------------------------
code, body = request(f"{WM}/api/workspaces/list", token=token)
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
        f"{WM}/api/workspaces/create", method="POST", body=payload, token=token
    )
    if code == 400 and "username" in body.lower() and "not allowed" not in body.lower():
        payload["username"] = "idan"
        code, body = request(
            f"{WM}/api/workspaces/create", method="POST", body=payload, token=token
        )

    if code < 300:
        log(f"CHANGE: created workspace '{workspace}'")
    elif code == 400 and "already exists" in body.lower():
        log(f"workspace '{workspace}' already exists")
    else:
        fatal(f"POST /api/workspaces/create returned {code}: {body[:400]}")

# ---------------------------------------------------------------------------
# 4. Add the non-admin users to the workspace (BEST-EFFORT)
# ---------------------------------------------------------------------------
# The instance accounts (step 1) are what let them log in — that is the tier-2b
# guarantee. Workspace membership is a convenience on top, and the add endpoint
# is version-sensitive (add vs invite; body shape), so a non-2xx here is a
# WARNING, never fatal — it must not break the idempotency contract or the
# stack. Re-runs: an already-member response is treated as a no-op.
for email, _, is_super in roster:
    if is_super:
        continue  # superadmins already have access to every workspace
    code, body = request(
        f"{WM}/api/w/{workspace}/users/add",
        method="POST",
        body={"email": email, "is_admin": False, "operator": False},
        token=token,
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

# ---------------------------------------------------------------------------
# 5. Retire the default account
# ---------------------------------------------------------------------------
# ⚠ The verb is DELETE — a POST to the same path 405s, an easy way to
# "retire" an account that is still live.
# 🚨 THE DELETE IS NOT DISTINGUISHABLE: 2xx whether or not the account
# existed, so deleting unconditionally + logging CHANGE prints a change line
# EVERY run and breaks the idempotency contract (the suite caught exactly
# this). Look first; claim a change only when there was one.
def default_admin_exists():
    """None when the answer cannot be determined."""
    code, body = request(
        f"{WM}/api/users/list_as_super_admin?per_page=1000", token=token
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
        f"{WM}/api/users/delete/{DEFAULT_ADMIN}", method="DELETE", token=token
    )
    if code >= 300 and code not in (404, 400):
        fatal(
            f"DELETE /api/users/delete/{DEFAULT_ADMIN} returned {code}: "
            f"{body[:400]}"
        )
    if present is True:
        log(f"CHANGE: deleted the default {DEFAULT_ADMIN} account")
    else:
        # Could not read the user list, so the delete was issued blind. Say so
        # rather than claiming a change — a wrong CHANGE line is worse than an
        # honest unknown, because the whole contract is "a second run prints
        # none".
        log(
            f"delete requested for {DEFAULT_ADMIN}; could not determine "
            f"whether it existed (user list unavailable)"
        )

log("done")
PY
