#!/bin/sh
# tracking-init — headless first-run for Homebox and Karakeep (annex §3).
# Runs in python:3.13-alpine as a oneshot once both are healthy.
#
# BookStack is deliberately NOT handled here: it has no HTTP path to a first
# admin at all, so it is provisioned from inside its own container by
# bookstack-admin-init.sh.
#
# Contract (media-init pattern):
#   - Every mutation logs "tracking-init: CHANGE: ...". A second run — every
#     Arcane redeploy reruns this container — must log ZERO change lines.
#   - Unset credentials are a HARD error (decrypt race, finding #11).
#
# Both apps have the same pleasant property: the FIRST user created becomes
# the owner/admin, with no separate promotion step.
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
             f"{', '.join(missing)} (decrypt race? finding #11)")

# ===========================================================================
# Homebox
# ===========================================================================
# Registration is open by default, and the first user to register with an
# EMPTY group token becomes the group owner — that is the whole bootstrap.
#
# Two shapes to know: the response is 204 with NO BODY (so anything checking
# for JSON fails), and the login field is `username`, not `email`.
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
    # 🚨 Homebox answers **500**, not a 4xx, for an already-registered email:
    #     {"error":"ent: constraint failed: constraint failed: UNIQUE
    #      constraint failed: users.email (2067)"}
    # The ent constraint violation is not translated into a client error at
    # all. Verified from a suite run — the second pass of this script exited 1
    # and broke the idempotency contract, which is exactly the failure that
    # every Arcane redeploy would have hit.
    #
    # So the accepted set includes 500, and a UNIQUE-constraint body is treated
    # as "already exists". That is deliberately narrow: a 500 for any OTHER
    # reason must still be fatal, because "the server broke" and "the user is
    # already there" are not the same thing and only the body distinguishes
    # them here.
    already_exists = (
        e.code in (400, 409, 422)
        or (e.code == 500 and "UNIQUE constraint failed: users.email" in body)
    )
    if not already_exists:
        sys.exit(f"tracking-init: FATAL: homebox register HTTP {e.code}: {body}")
    log("homebox user already exists - no change")

# Whether it was just created or already existed, prove the credentials work —
# otherwise "already exists" silently covers "exists with a different
# password", which is the same ambiguity that bit the books stack.
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
# Signup is a tRPC publicProcedure, not REST: there is no POST /api/v1/users
# and no /api/auth/signup. The first user created automatically becomes admin.
#
# ⚠ The {"json": ...} wrapper is MANDATORY — this is tRPC v11 with the
# superjson transformer, and a flat body fails validation in a way that reads
# like a schema error. confirmPassword is a .refine(), not a default.
#
# ⚠ Ordering: DISABLE_PASSWORD_AUTH=true disables BOTH users.create and
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

# Same reasoning as Homebox: prove the credentials work, rather than letting
# "already exists" quietly cover "exists with a different password".
# `exchange` is the headless path — its sibling `apiKeys.create` requires a
# browser cookie.
#
# 🚨 THE KEY NAME MUST BE UNIQUE PER RUN. A fixed name works exactly once:
# the second call returns
#   500 {"code":"INTERNAL_SERVER_ERROR","path":"apiKeys.exchange"}
# — a unique-constraint violation surfaced as a generic 500, with nothing in
# the body to distinguish it from a real fault. An earlier version of this
# script used the fixed name "tracking-init" and a comment claiming the cost
# was "one key accumulates per redeploy". That was wrong in the worse
# direction: it did not accumulate, it made every redeploy exit 1. Found by
# the suite rerunning this container, which is the only way to find it.
#
# So: mint under a nonce name, verify, then revoke it again. That keeps the
# credential check on EVERY run — silent password drift is what it exists for,
# and `users.create` returning a duplicate error says nothing about the
# password — without leaving a key behind each time.
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

# Best-effort cleanup, deliberately NOT fatal. The verification above has
# already done its job by this point, and failing the whole provisioning run
# over a leftover verification key would be the wrong trade — but say so out
# loud, because a key nobody knows about is worse than one they were told to
# revoke.
if key.get("id"):
    try:
        call(f"{KARAKEEP}/api/trpc/apiKeys.revoke", "POST",
             {"json": {"id": key["id"]}},
             headers={"Authorization": f"Bearer {key['key']}"})
    except Exception as exc:
        log(f"WARNING: could not revoke the verification key {key_name!r} "
            f"({exc}) - revoke it by hand in Karakeep's settings")
else:
    log(f"WARNING: apiKeys.exchange returned no id, so the verification key "
        f"{key_name!r} could not be revoked - remove it by hand")

log(f"done ({changes} change(s))")
PY
