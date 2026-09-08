#!/bin/sh
# tracking-init — headless first-run for Homebox and Karakeep. Runs in
# python:3.13-alpine as a oneshot once both are healthy; BookStack has no HTTP
# path to a first admin and is handled by bookstack-admin-init.sh.
#
# Every mutation logs "tracking-init: CHANGE: ..." and a second run must log
# ZERO change lines. Unset credentials are a hard error.
#
# In both apps the FIRST user created becomes the owner, with no promotion
# step.
set -eu

exec python3 - <<'PY'
import json
import os
import sys
import time
import urllib.error
import urllib.request

HOMEBOX = os.environ.get("HOMEBOX_URL", "http://homebox:7745")
KARAKEEP = os.environ.get("KARAKEEP_URL", "http://karakeep:3000")

changes = 0


def log(msg):
    print(f"tracking-init: {msg}", flush=True)


def change(msg):
    global changes
    changes += 1
    print(f"tracking-init: CHANGE: {msg}", flush=True)


def call(url, method="GET", body=None, headers=None, timeout=60):
    """Returns (status, parsed-json-or-text). Raises HTTPError to the caller."""
    data = None
    hdrs = dict(headers or {})
    if body is not None:
        data = json.dumps(body).encode()
        hdrs["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=hdrs, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read().decode(errors="replace")
        try:
            return resp.status, json.loads(raw) if raw else None
        except ValueError:
            return resp.status, raw


def detail(exc):
    try:
        return exc.read().decode(errors="replace")[:500]
    except Exception:
        return ""


required = ("HOMEBOX_ADMIN_EMAIL", "HOMEBOX_ADMIN_PASSWORD",
            "KARAKEEP_ADMIN_EMAIL", "KARAKEEP_ADMIN_PASSWORD")
missing = [k for k in required if not os.environ.get(k)]
if missing:
    sys.exit(f"tracking-init: FATAL: unset or empty in .env: "
             f"{', '.join(missing)} (decrypt race?)")

# ===========================================================================
# Homebox
# ===========================================================================
# The first user to register with an EMPTY group token becomes the group
# owner. Two shapes to know: the response is 204 with NO BODY, and the login
# field is `username`, not `email`.
_, status = call(f"{HOMEBOX}/api/v1/status")
if not isinstance(status, dict):
    sys.exit(f"tracking-init: FATAL: unexpected homebox /status: {status!r}")

try:
    call(f"{HOMEBOX}/api/v1/users/register", "POST", {
        "name": os.environ.get("HOMEBOX_ADMIN_NAME", "Admin"),
        "email": os.environ["HOMEBOX_ADMIN_EMAIL"],
        "password": os.environ["HOMEBOX_ADMIN_PASSWORD"],
        # Empty token => create a new group and own it.
        "token": "",
    })
    change(f"homebox owner {os.environ['HOMEBOX_ADMIN_EMAIL']} registered")
except urllib.error.HTTPError as e:
    body = detail(e)
    # 🚨 Homebox answers 500, not 4xx, for an already-registered email, so
    # every redeploy would otherwise exit 1. Deliberately narrow: only the
    # UNIQUE-constraint body distinguishes "already there" from "broke".
    already_exists = (
        e.code in (400, 409, 422)
        or (e.code == 500 and "UNIQUE constraint failed: users.email" in body)
    )
    if not already_exists:
        sys.exit(f"tracking-init: FATAL: homebox register HTTP {e.code}: {body}")
    log("homebox user already exists - no change")

# Prove the credentials work either way, so "already exists" cannot silently
# cover "exists with a different password".
try:
    call(f"{HOMEBOX}/api/v1/users/login", "POST", {
        "username": os.environ["HOMEBOX_ADMIN_EMAIL"],
        "password": os.environ["HOMEBOX_ADMIN_PASSWORD"],
    })
except urllib.error.HTTPError as e:
    sys.exit(f"tracking-init: FATAL: homebox login HTTP {e.code}: {detail(e)} "
             f"(a user exists but these credentials do not match it — did "
             f".env change after the first seed?)")

# ===========================================================================
# Karakeep
# ===========================================================================
# Signup is a tRPC publicProcedure, not REST. The first user created becomes
# admin automatically.
#
# ⚠ The {"json": ...} wrapper is MANDATORY (tRPC v11 + superjson); a flat body
# fails validation in a way that reads like a schema error, and
# confirmPassword is a .refine(), not a default.
#
# ⚠ DISABLE_PASSWORD_AUTH=true disables BOTH users.create and
# apiKeys.exchange, so this has to run before any lock-down to OIDC-only.
karakeep_user = {
    "name": os.environ.get("KARAKEEP_ADMIN_NAME", "Admin"),
    "email": os.environ["KARAKEEP_ADMIN_EMAIL"],
    "password": os.environ["KARAKEEP_ADMIN_PASSWORD"],
    "confirmPassword": os.environ["KARAKEEP_ADMIN_PASSWORD"],
}
try:
    _, res = call(f"{KARAKEEP}/api/trpc/users.create", "POST",
                  {"json": karakeep_user})
    created = ((res or {}).get("result") or {}).get("data") or {}
    role = (created.get("json") or {}).get("role")
    change(f"karakeep admin {karakeep_user['email']} created (role {role})")
except urllib.error.HTTPError as e:
    body = detail(e)
    if e.code not in (400, 409, 422):
        sys.exit(f"tracking-init: FATAL: karakeep users.create HTTP {e.code}: "
                 f"{body}")
    log("karakeep user already exists - no change")

# Same credential proof as Homebox. `exchange` is the headless path — its
# sibling `apiKeys.create` requires a browser cookie.
#
# 🚨 THE KEY NAME MUST BE UNIQUE PER RUN: a fixed one works exactly once, and
# the second call returns a generic 500 that made every redeploy exit 1. Mint
# under a nonce name, verify, revoke.
nonce = str(int(time.time()))
key_name = f"tracking-init-{nonce}"
try:
    _, res = call(f"{KARAKEEP}/api/trpc/apiKeys.exchange", "POST", {"json": {
        "keyName": key_name,
        "email": os.environ["KARAKEEP_ADMIN_EMAIL"],
        "password": os.environ["KARAKEEP_ADMIN_PASSWORD"],
    }})
except urllib.error.HTTPError as e:
    sys.exit(f"tracking-init: FATAL: karakeep apiKeys.exchange HTTP {e.code}: "
             f"{detail(e)} (a user exists but these credentials do not match "
             f"it, or DISABLE_PASSWORD_AUTH is set — which disables both "
             f"user creation and this endpoint)")

key = (((res or {}).get("result") or {}).get("data") or {}).get("json") or {}
if not key.get("key"):
    sys.exit(f"tracking-init: FATAL: apiKeys.exchange returned no key: {res!r}")
log("karakeep credentials verified (api key mintable)")

# Sweep the leftovers first, while this key is still valid. A revoke below
# that fails is only a WARNING, so a run of failures would accumulate LIVE
# full-access keys with nothing to clean them up. Best-effort and silent when
# there is nothing to do: apiKeys.list is a tRPC query, so any shape surprise
# degrades to one WARNING rather than failing a deploy.
kk_auth = {"Authorization": f"Bearer {key['key']}"}
try:
    _, listed = call(f"{KARAKEEP}/api/trpc/apiKeys.list", "GET", None, kk_auth)
    existing = ((((listed or {}).get("result") or {}).get("data") or {})
                .get("json") or {}).get("keys") or []
    stale = [k for k in existing
             if isinstance(k, dict)
             and str(k.get("name", "")).startswith("tracking-init-")
             and k.get("id") and k["id"] != key.get("id")]
    for old_key in stale:
        call(f"{KARAKEEP}/api/trpc/apiKeys.revoke", "POST",
             {"json": {"id": old_key["id"]}}, kk_auth)
        change(f"karakeep: revoked a leftover verification key "
               f"{old_key.get('name')!r} (an earlier revoke had failed)")
except Exception as exc:  # noqa: BLE001
    log(f"WARNING: could not sweep leftover verification keys ({exc}) - check "
        f"Karakeep's settings for stale tracking-init-* keys")

# Best-effort, deliberately not fatal — but said out loud, because a key
# nobody knows about is worse than one they were told to revoke.
if key.get("id"):
    try:
        call(f"{KARAKEEP}/api/trpc/apiKeys.revoke", "POST",
             {"json": {"id": key["id"]}}, kk_auth)
    except Exception as exc:
        log(f"WARNING: could not revoke the verification key {key_name!r} "
            f"({exc}) - revoke it by hand in Karakeep's settings")
else:
    log(f"WARNING: apiKeys.exchange returned no id, so the verification key "
        f"{key_name!r} could not be revoked - remove it by hand")

log(f"done ({changes} change(s))")
PY
