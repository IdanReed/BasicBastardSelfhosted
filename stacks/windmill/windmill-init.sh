#!/bin/sh
# Headless first-run for Windmill (annex §3.4).
#
# WHY THIS EXISTS: upstream's documented setup is "deploy, log in as
# admin@windmill.dev / changeme, then use the Instance Settings UI". There is
# no forced password change, so the published default credential is live from
# the moment the server starts until a human intervenes.
#
# SUPERADMIN_SECRET is the documented way out — the binary's own --help calls
# it a "virtual superadmin token (server)" — and presenting it as a bearer
# token authenticates against the ordinary API without ever using `changeme`.
#
# Every mutation logs "windmill-init: CHANGE: ...". A second run — and every
# Arcane redeploy reruns this container — must log ZERO change lines.
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


def log(msg):
    print(f"windmill-init: {msg}", flush=True)


def fatal(msg):
    print(f"windmill-init: FATAL: {msg}", flush=True)
    sys.exit(1)


def env(name):
    v = os.environ.get(name, "").strip()
    if not v:
        # Fail loudly. An unset variable here means the .env did not decrypt,
        # and "unprovisioned" for Windmill means admin@windmill.dev / changeme
        # stays live on a service that runs arbitrary code.
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
admin_email = env("WINDMILL_ADMIN_EMAIL").lower()
admin_pass = env("WINDMILL_ADMIN_PASSWORD")
workspace = os.environ.get("WINDMILL_WORKSPACE", "main").strip() or "main"

if admin_email == DEFAULT_ADMIN:
    fatal(f"WINDMILL_ADMIN_EMAIL must not be {DEFAULT_ADMIN}")
if len(admin_pass) < 12:
    fatal("WINDMILL_ADMIN_PASSWORD must be at least 12 characters")

wait_for_server()

# ---------------------------------------------------------------------------
# 1. The real superadmin
# ---------------------------------------------------------------------------
code, body = request(
    f"{WM}/api/users/create",
    method="POST",
    body={"email": admin_email, "password": admin_pass, "super_admin": True},
    token=secret,
)
if code < 300:
    log(f"CHANGE: created superadmin {admin_email}")
elif code == 400 and "already exists" in body.lower():
    log(f"superadmin {admin_email} already exists")
else:
    # 401/403 here means SUPERADMIN_SECRET is not being accepted, which is the
    # difference between "provisioned" and "changeme is still live". Never
    # swallow it.
    fatal(f"POST /api/users/create returned {code}: {body[:400]}")

# ---------------------------------------------------------------------------
# 2. Log in AS that user for everything else
# ---------------------------------------------------------------------------
# Not the superadmin token: whether the virtual-superadmin bearer can complete
# workspace creation is not something this script should bet on, and a real
# session is the path the UI uses anyway. If login fails, step 1 lied.
code, body = request(
    f"{WM}/api/auth/login",
    method="POST",
    body={"email": admin_email, "password": admin_pass},
)
if code >= 300:
    fatal(f"login as {admin_email} returned {code}: {body[:400]}")
token = body.strip().strip('"')
if not token:
    fatal("login returned an empty token")

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
        payload["username"] = admin_email.split("@")[0]
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
# 4. Retire the default account
# ---------------------------------------------------------------------------
# ⚠ The verb is DELETE. The openapi operation is `globalUserDelete` and a POST
# to the same path 405s — an easy way to "retire" an account that is still
# live, since a 405 in a script nobody reads looks like any other line.
code, body = request(
    f"{WM}/api/users/delete/{DEFAULT_ADMIN}", method="DELETE", token=token
)
if code < 300:
    log(f"CHANGE: deleted the default {DEFAULT_ADMIN} account")
elif code in (404, 400):
    log(f"{DEFAULT_ADMIN} already gone")
else:
    fatal(f"DELETE /api/users/delete/{DEFAULT_ADMIN} returned {code}: {body[:400]}")

log("done")
PY
