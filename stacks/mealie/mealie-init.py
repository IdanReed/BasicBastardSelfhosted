# Headless first-run for Mealie — retires the boot-time default admin
# (changeme@example.com / MyPassword), which v3 creates on an empty database
# with no env-var path to change it.
#
# Through the app's own REST API, in order: try the real admin's login; else log
# in as the default and create the real admin; log in as it, proving the new
# credential BEFORE the fallback is destroyed; delete the default; assert
# startup-info agrees.
#
# Every mutation prints "mealie-init: CHANGE: ...". A second run — every
# redeploy reruns this container — must print ZERO change lines.
#
# ⚠ Repair, not reset: if the real admin's password was changed in the UI this
# FAILS LOUDLY rather than guess. Update .env or the UI password.

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

BASE = os.environ.get("MEALIE_BASE_URL", "http://mealie:9000").rstrip("/")
DEFAULT_EMAIL = "changeme@example.com"
DEFAULT_PASSWORD = "MyPassword"


def log(msg):
    print(f"mealie-init: {msg}", flush=True)


def fatal(msg):
    print(f"mealie-init: FATAL: {msg}", flush=True)
    sys.exit(1)


def env(name):
    v = os.environ.get(name, "").strip()
    if not v:
        # Unset means the .env did not decrypt, and an unprovisioned Mealie
        # keeps serving the published default admin.
        fatal(f"{name} is unset or empty")
    return v


def req(method, path, token=None, json_body=None, form=None):
    """Returns (status, parsed-json-or-text). Never raises on HTTP errors."""
    headers = {}
    data = None
    if form is not None:
        data = urllib.parse.urlencode(form).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    elif json_body is not None:
        data = json.dumps(json_body).encode()
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    r = urllib.request.Request(BASE + path, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(r, timeout=30) as resp:
            body = resp.read()
            return resp.status, json.loads(body) if body else None
    except urllib.error.HTTPError as e:
        body = e.read()
        try:
            return e.code, json.loads(body)
        except (ValueError, UnicodeDecodeError):
            return e.code, body.decode(errors="replace")
    except urllib.error.URLError as e:
        fatal(f"cannot reach {BASE}{path}: {e.reason}")


def login(identity, password):
    # /api/auth/token takes FORM data (CredentialsRequestForm), not JSON.
    # `username` accepts the email too — the UI itself logs in by email.
    code, body = req("POST", "/api/auth/token", form={"username": identity, "password": password})
    if code == 200:
        return body["access_token"]
    if code == 401:
        return None
    if code == 423:
        # 5 attempts, then a 24h lockout — never retry into it.
        fatal(f"{identity} is LOCKED OUT (HTTP 423) — unlock via "
              "POST /api/admin/users/unlock or wait out the lockout window")
    fatal(f"unexpected {code} from /api/auth/token for {identity}: {body}")


admin_user = env("MEALIE_ADMIN_USER")
admin_email = env("MEALIE_ADMIN_EMAIL").lower()  # the API lowercases emails
admin_password = env("MEALIE_ADMIN_PASSWORD")

if len(admin_password) < 12:
    fatal("MEALIE_ADMIN_PASSWORD must be at least 12 characters")
if admin_password.startswith("changeme_"):
    fatal("MEALIE_ADMIN_PASSWORD is still the .sops.env.example placeholder")
if admin_password == DEFAULT_PASSWORD:
    fatal("MEALIE_ADMIN_PASSWORD must not be the published default 'MyPassword'")
if admin_user == "admin":
    # The default's username: creating the real account would 409 on it.
    fatal("MEALIE_ADMIN_USER must not be 'admin' — that is the default "
          "account this script exists to retire")
if admin_email == DEFAULT_EMAIL:
    fatal("MEALIE_ADMIN_EMAIL must not be changeme@example.com")

token = login(admin_email, admin_password)
if token:
    log(f"admin {admin_user} already exists and its password works")
else:
    default_token = login(DEFAULT_EMAIL, DEFAULT_PASSWORD)
    if default_token is None:
        fatal("neither the configured admin nor the boot-time default can "
              "log in — refusing to guess at this instance's state (was the "
              "admin password changed in the UI without updating .sops.env?)")
    code, body = req("POST", "/api/admin/users", token=default_token, json_body={
        "username": admin_user,
        "fullName": admin_user,
        "email": admin_email,
        "password": admin_password,  # hashed server-side by the route
        "admin": True,
        # Explicit rather than trusting model defaults; these are the names
        # init_db creates when DEFAULT_GROUP/DEFAULT_HOUSEHOLD are unset in
        # compose.yaml — keep all three in lockstep if that ever changes.
        "group": "Home",
        "household": "Family",
    })
    if code != 201:
        fatal(f"creating admin {admin_user} failed: {code} {body}")
    log(f"CHANGE: created admin {admin_user}")

    # Prove the new credential BEFORE deleting the only other admin.
    token = login(admin_email, admin_password)
    if token is None:
        fatal("the admin that was just created cannot log in")

# Retire the default admin — also heals a run that died between create and
# delete. perPage=-1 is the API's "all rows".
code, body = req("GET", "/api/admin/users?perPage=-1", token=token)
if code != 200:
    fatal(f"listing users failed: {code} {body}")
stale = [u for u in body["items"] if u["email"] == DEFAULT_EMAIL]
for u in stale:
    code, resp = req("DELETE", f"/api/admin/users/{u['id']}", token=token)
    if code != 200:
        fatal(f"deleting the default admin failed: {code} {resp}")
    log("CHANGE: deleted the default admin (changeme@example.com)")
if not stale:
    log("default admin already retired")

# startup-info reports isFirstLogin=true exactly when a changeme@example.com
# user exists — the app's own signal, and the suite's assertion hook.
code, body = req("GET", "/api/app/about/startup-info")
if code != 200 or body.get("isFirstLogin"):
    fatal(f"startup-info still reports the default admin present: {code} {body}")

log("done")
