#!/bin/sh
# cleanuparr-init — the first-run account and the Authentik sign-in. Runs in
# python:3.13-alpine as a oneshot once cleanuparr is healthy.
#
# WHY IT WORKS: Cleanuparr has exactly one account. /api/auth/setup/* is
# anonymous until that account exists and is marked complete, and the API
# never requires the wizard's 2FA step. The OIDC settings are columns on the
# same account (PUT /api/account/oidc), so its password login writes them.
# None of it touches the network: Cleanuparr fetches discovery at sign-in,
# so this runs, and Cleanuparr boots, with Authentik down.
#
# Declared state: the account CLEANUPARR_ADMIN_USER with
# CLEANUPARR_ADMIN_PASSWORD, OIDC on against Authentik's cleanuparr-sso
# application (Admin group only), and exclusive mode OFF, so the password stays
# beside it as break-glass. The optional Link Account step (pinning OIDC to one
# Authentik identity) is left to the UI; the PUT never touches it.
#
# The client secret is masked on read and cannot be compared, so it is written
# on every run — which is also what carries a rotation. Every other mutation
# logs "cleanuparr-init: CHANGE: ..."; a second run must log ZERO.
#
# ⚠ The password is set once, when the account is created. `sopsgen rotate
# user/idan` changes what this init SIGNS IN with, not what Cleanuparr
# stores, and the next run fails loudly: change it under Settings > Account
# first.
set -eu

exec python3 -u - <<'PY'
import json
import os
import sys
import urllib.error
import urllib.request

BASE = os.environ.get("CLEANUPARR_URL", "http://cleanuparr:11011")
CHANGES = 0


def log(msg):
    print(f"cleanuparr-init: {msg}", flush=True)


def change(msg):
    global CHANGES
    CHANGES += 1
    print(f"cleanuparr-init: CHANGE: {msg}", flush=True)


def fatal(msg):
    sys.exit(f"cleanuparr-init: FATAL: {msg}")


def call(path, method="GET", body=None, token=None, timeout=60):
    data = None
    headers = {"Accept": "application/json"}
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(BASE + path, data=data, headers=headers,
                                 method=method)
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


def field(obj, name):
    # The API writes camelCase; read case-insensitively rather than bet on it.
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k.lower() == name.lower():
                return v
    return None


required = ("CLEANUPARR_ADMIN_USER", "CLEANUPARR_ADMIN_PASSWORD",
            "CLEANUPARR_OIDC_ISSUER_URL", "CLEANUPARR_OIDC_CLIENT_ID",
            "CLEANUPARR_OIDC_CLIENT_SECRET", "CLEANUPARR_PUBLIC_URL")
missing = [k for k in required if not os.environ.get(k)]
if missing:
    fatal(f"unset or empty: {', '.join(missing)} (decrypt race?)")
placeholder = [k for k in required if os.environ[k].startswith("changeme")]
if placeholder:
    fatal(f"still the changeme placeholder: {', '.join(placeholder)}")

USER = os.environ["CLEANUPARR_ADMIN_USER"]
PASSWORD = os.environ["CLEANUPARR_ADMIN_PASSWORD"]

# 1. The account. While setup is open the first caller to POST it owns the
# instance, so it is claimed here rather than left for a visitor.
_, status = call("/api/auth/status")
if not field(status, "setupCompleted"):
    try:
        call("/api/auth/setup/account", "POST",
             {"username": USER, "password": PASSWORD})
        change(f"created the admin account {USER!r}")
    except urllib.error.HTTPError as e:
        # 409: an account exists but setup was never completed (a run that
        # died between the two calls). Completing it is safe: the login below
        # proves whether it is ours.
        if e.code != 409:
            fatal(f"POST /api/auth/setup/account HTTP {e.code}: {detail(e)} "
                  f"(a 400 here is the password policy: 8-128 characters)")
        log("an unfinished account already exists - completing its setup")
    call("/api/auth/setup/complete", "POST")
    change("first-run setup completed")

# 2. Sign in.
try:
    _, login = call("/api/auth/login", "POST",
                    {"username": USER, "password": PASSWORD})
except urllib.error.HTTPError as e:
    hint = {
        401: "the stored password is not CLEANUPARR_ADMIN_PASSWORD (rotated "
             "user/idan, or the account was claimed by hand): set it under "
             "Settings > Account",
        403: "exclusive mode was turned on in the UI, which disables password "
             "login: turn it off under Settings > Account",
        429: "the account is locked out after failed logins: wait, then rerun",
    }.get(e.code, "unexpected")
    fatal(f"POST /api/auth/login HTTP {e.code}: {detail(e)} ({hint})")
if field(login, "requiresTwoFactor"):
    fatal("2FA was enabled in the UI, which this init cannot answer: disable "
          "it under Settings > Account (Authentik already enforces MFA)")
tokens = field(login, "tokens")
token = field(tokens, "accessToken")
if not token:
    fatal(f"login returned no access token: {str(login)[:200]}")

# 3. The OIDC settings.
want = {
    "enabled": True,
    "providerName": "Authentik",
    "issuerUrl": os.environ["CLEANUPARR_OIDC_ISSUER_URL"],
    "clientId": os.environ["CLEANUPARR_OIDC_CLIENT_ID"],
    "scopes": "openid profile email",
    # The callbacks are this plus /api/auth/oidc/callback and
    # /api/account/oidc/link/callback — the blueprint's redirect URIs.
    "redirectUrl": os.environ["CLEANUPARR_PUBLIC_URL"],
    "exclusiveMode": False,
}
_, have = call("/api/account/oidc", token=token)
drift = sorted(k for k, v in want.items() if field(have, k) != v)
try:
    call("/api/account/oidc", "PUT",
         dict(want, clientSecret=os.environ["CLEANUPARR_OIDC_CLIENT_SECRET"]),
         token=token)
except urllib.error.HTTPError as e:
    fatal(f"PUT /api/account/oidc HTTP {e.code}: {detail(e)}")
if drift:
    change(f"OIDC settings written ({', '.join(drift)})")
else:
    log("OIDC settings unchanged; client secret re-written")

# Revoke this run's refresh token, so redeploys do not pile up live sessions.
refresh = field(tokens, "refreshToken")
if refresh:
    try:
        call("/api/auth/logout", "POST", {"refreshToken": refresh})
    except urllib.error.HTTPError as e:
        log(f"WARN: logout HTTP {e.code}: {detail(e)}")

log(f"done ({CHANGES} change(s))")
PY
