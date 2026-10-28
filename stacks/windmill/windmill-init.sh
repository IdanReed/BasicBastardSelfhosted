#!/bin/sh
# Headless first-run for Windmill (annex §3.4). Upstream's documented setup is
# "log in as admin@windmill.dev / changeme, then use the UI" with no forced
# password change, so the published default is live until a human intervenes.
# SUPERADMIN_SECRET presented as a bearer token authenticates against the
# ordinary API without ever using `changeme`.
#
# Roster: idan is the super_admin, with his one password (IDAN_INITIAL_PASSWORD,
# the same value Authentik sets). Windmill runs arbitrary code, so nobody else
# gets an account by default: an invited user is added as one roster line on
# login_type 'authentik', which needs no password of theirs.
#
# SSO: the published CE image is built with the private OAuth code (`ce` pulls
# in `private` + `oauth2`; only the SOURCE build's oauth2_oss.rs stub returns
# no logins) and allows up to 10 SSO accounts. This script writes the
# `authentik` provider into the `oauths` instance setting — the exact shape the
# Instance Settings UI saves — and sets require_preexisting_user_for_oauth, so
# SSO changes how roster users log in, never who has an account.
# 🚨 A Windmill account has ONE login_type. Login matches by email but refuses
# an account whose login_type is not the provider's name ("exists but with a
# different login type"), and password login only accepts login_type
# 'password'. Each roster entry therefore names its login type: idan stays
# 'password' as the UI break-glass superadmin (and the suite logs in with it);
# SSO entries are 'authentik' and are created with a random password that
# nothing ever uses. Repair for a locked-out SSO account: give its entry a
# password env and "password", and redeploy.
#
# Every mutation logs "windmill-init: CHANGE: ...". A second run — every
# redeploy reruns this container — must log ZERO change lines.
set -eu

python3 - <<'PY'
import json
import os
import secrets
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

WM = "http://windmill_server:8000"
DEFAULT_ADMIN = "admin@windmill.dev"

# Authentik. The provider key is also the callback path segment
# (/user/login_callback/authentik) and the login_type SSO accounts carry.
SSO_PROVIDER = "authentik"
SSO_ISSUER = "https://auth.idanreed.com"
SSO_CLIENT_ID = "windmill"

# (email, password_env, super_admin, login_type). password_env is None for an
# SSO entry. A create is a no-op for an existing account, so an
# already-provisioned user keeps whatever password they have; login_type is
# re-asserted every run. The email is the Authentik account's, which is what
# SSO matches on — an invited user's is the one fixed in their invitation:
#     ("them@example.com", None, False, SSO_PROVIDER),
USERS = [
    ("idan@idanreed.com", "IDAN_INITIAL_PASSWORD", True, "password"),
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
sso_secret = env("WINDMILL_OIDC_CLIENT_SECRET")
workspace = os.environ.get("WINDMILL_WORKSPACE", "main").strip() or "main"

# Resolve passwords up front so a missing/short one fails before any mutation.
roster = []
for email, pw_env, is_super, login_type in USERS:
    email = email.lower()
    if email == DEFAULT_ADMIN:
        fatal(f"roster email must not be {DEFAULT_ADMIN}")
    if login_type not in ("password", SSO_PROVIDER):
        fatal(f"{email}: login_type must be 'password' or '{SSO_PROVIDER}'")
    if pw_env is None:
        if login_type == "password":
            fatal(f"{email}: a 'password' login needs a password env")
        # Never usable: password login refuses an SSO account.
        pw = secrets.token_urlsafe(32)
    else:
        pw = env(pw_env)
        if len(pw) < 12:
            fatal(f"{pw_env} must be at least 12 characters")
    roster.append((email, pw, is_super, login_type))
if not any(s and lt == "password" for _, _, s, lt in roster):
    # Without one password superadmin the UI has no way in while Authentik is
    # down, short of SUPERADMIN_SECRET over loopback.
    fatal("the roster must keep one superadmin on login_type 'password'")

wait_for_server()

# Every admin operation below uses the SUPERADMIN_SECRET bearer, never a
# login-as-a-user session — which also sidesteps a 401 when a stored password
# differs from the account's real one.

# Users — idempotent, 400 "already exists" is a no-op
for email, pw, is_super, _ in roster:
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
for email, _, is_super, _ in roster:
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
def list_users():
    """{email: login_type} for every instance user; None when unavailable."""
    code, body = request(
        f"{WM}/api/users/list_as_super_admin?per_page=1000", token=secret
    )
    if code >= 300 or not body:
        return None
    try:
        return {
            (u.get("email") or "").lower(): u.get("login_type")
            for u in json.loads(body)
        }
    except (ValueError, AttributeError, TypeError):
        return None


def default_admin_exists():
    """None when the answer cannot be determined."""
    users = list_users()
    return None if users is None else DEFAULT_ADMIN in users


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

# SSO
# AFTER the default account is gone, so a failure here never leaves
# admin@windmill.dev / changeme live. Order within: pre-existing-only first,
# then the provider (no window where any Authentik account could self-provision
# one), then login types (no account is flipped before its provider exists).
# Every setting is read back and written only on a difference; GET returns the
# stored JSON verbatim, secret included, so a rotation is seen.
def get_setting(key):
    code, body = request(f"{WM}/api/settings/global/{key}", token=secret)
    if code >= 300:
        fatal(f"GET /api/settings/global/{key} returned {code}: {body[:400]}")
    try:
        return json.loads(body) if body else None
    except ValueError:
        fatal(f"GET /api/settings/global/{key} returned non-JSON: {body[:200]}")


def set_setting(key, value):
    code, body = request(
        f"{WM}/api/settings/global/{key}",
        method="POST",
        body={"value": value},
        token=secret,
    )
    if code >= 300:
        fatal(f"POST /api/settings/global/{key} returned {code}: {body[:400]}")


if get_setting("require_preexisting_user_for_oauth") is True:
    log("SSO already limited to existing accounts")
else:
    set_setting("require_preexisting_user_for_oauth", True)
    log("CHANGE: limited SSO to existing accounts")

# Field for field what AuthentikSetting.svelte derives from the base URL, so
# opening and saving the settings page is not a difference. offline_access is
# what the UI requests; Authentik drops a scope the provider does not map.
# The client secret never reaches the log.
desired = {
    "id": SSO_CLIENT_ID,
    "secret": sso_secret,
    "display_name": "Authentik",
    "connect_config": {
        "auth_url": f"{SSO_ISSUER}/application/o/authorize/",
        "token_url": f"{SSO_ISSUER}/application/o/token/",
        "scopes": ["openid", "offline_access"],
    },
    "login_config": {
        "auth_url": f"{SSO_ISSUER}/application/o/authorize/",
        "token_url": f"{SSO_ISSUER}/application/o/token/",
        "userinfo_url": f"{SSO_ISSUER}/application/o/userinfo/",
        "scopes": ["openid", "offline_access", "email"],
    },
}
oauths = get_setting("oauths")
if oauths is None:
    oauths = {}
if not isinstance(oauths, dict):
    fatal(f"the oauths setting is not an object ({type(oauths).__name__})")
if oauths.get(SSO_PROVIDER) == desired:
    log(f"{SSO_PROVIDER} SSO provider already configured")
else:
    # Merge, never replace: other providers set in the UI stay.
    verb = "updated" if SSO_PROVIDER in oauths else "added"
    set_setting("oauths", {**oauths, SSO_PROVIDER: desired})
    log(f"CHANGE: {verb} the {SSO_PROVIDER} SSO provider (client {SSO_CLIENT_ID})")

users = list_users()
if users is None:
    log("WARN: user list unavailable; login types left unchanged")
else:
    for email, _, _, login_type in roster:
        current = users.get(email)
        if email not in users:
            log(f"WARN: {email} is not an instance user; login type not set")
        elif current == login_type:
            log(f"{email} already logs in with {login_type}")
        else:
            code, body = request(
                f"{WM}/api/users/set_login_type/"
                f"{urllib.parse.quote(email, safe='@')}",
                method="POST",
                body={"login_type": login_type},
                token=secret,
            )
            if code >= 300:
                fatal(f"POST /api/users/set_login_type ({email}) returned "
                      f"{code}: {body[:400]}")
            log(f"CHANGE: {email} login type {current!r} -> {login_type!r}")

log("done")
PY
