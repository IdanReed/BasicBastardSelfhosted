#!/bin/sh
# beszel-role — promote the env-seeded app user to `admin`.
#
# WHY IT EXISTS: initial-settings.go sets email, password and verified on the
# `users` row and NEVER `role`, and StartHub binds OnRecordCreate("users") to
# InitializeUserRole, which defaults it to "user". Only the UI's first-run path
# (CreateFirstUser) sets "admin". So the fleet's Beszel account is a non-admin
# and nothing says so.
#
# Runs AFTER the hub is healthy — beszel-init cannot do this, it exists to run
# before the hub starts.
#
# It also registers Authentik as the `users` collection's OAuth2 provider
# (`oidc`), from the same superuser session: that config lives only in
# data.db, with no env var, and the hub's own startup re-save leaves it alone.
# USER_CREATION stays unset, so Authentik signs in only to an account that
# already exists with that email — the env-seeded admin, whose password stays
# as break-glass (the record is verified, so PocketBase keeps it on linking).
#
# Every mutation logs "beszel-role: CHANGE:"; a second run must log zero.
# Unset credentials are a hard error (decrypt race); a hub whose superuser is
# not this pair is a WARN with the repair named, never a deploy failure.
set -eu

exec python3 -u - <<'PY'
import hashlib
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

BASE = os.environ.get("BESZEL_URL", "http://beszel:8090")

# Authentik's global endpoints: PocketBase's generic `oidc` provider takes the
# three URLs, not a discovery document, so nothing names the application slug
# (beszel-sso) and nothing contacts Authentik until someone logs in.
SSO_ISSUER = "https://auth.idanreed.com"
SSO_CLIENT_ID = "beszel"


def log(msg):
    print(f"beszel-role: {msg}", flush=True)


def change(msg):
    print(f"beszel-role: CHANGE: {msg}", flush=True)


def call(path, method="GET", body=None, token=None, timeout=60):
    data = None
    headers = {}
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    if token:
        # PocketBase reads the RAW token from this header — no Bearer prefix.
        headers["Authorization"] = token
    req = urllib.request.Request(BASE + path, data=data, headers=headers,
                                 method=method)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read().decode(errors="replace")
        try:
            return resp.status, json.loads(raw) if raw else None
        except ValueError:
            return resp.status, raw


REPAIR = ("docker compose -f /srv/komodo/stacks/beszel/stacks/beszel/compose.yaml -p beszel "
          "run --rm --entrypoint /beszel beszel superuser upsert <email> <pw>")

required = ("USER_EMAIL", "USER_PASSWORD", "BESZEL_OIDC_CLIENT_SECRET")
missing = [k for k in required if not os.environ.get(k)]
if missing:
    sys.exit(f"beszel-role: FATAL: unset or empty in .env: "
             f"{', '.join(missing)} (decrypt race?)")

EMAIL = os.environ["USER_EMAIL"]

# The email is interpolated into a PocketBase filter expression. Refuse the
# characters that could end the string literal rather than trying to escape
# them — no legal address needs one.
if any(c in EMAIL for c in ('"', "'", "\\", "\n", "\r")):
    log("WARN: USER_EMAIL carries a quote, backslash or newline — refusing to "
        "build a filter from it. Role left unchanged.")
    sys.exit(0)

# The env pair seeds a SUPERUSER and a matching app user in the same migration,
# so these credentials are the superuser's too.
try:
    _, auth = call("/api/collections/_superusers/auth-with-password", "POST",
                   {"identity": EMAIL, "password": os.environ["USER_PASSWORD"]})
except (urllib.error.HTTPError, urllib.error.URLError) as e:
    log(f"WARN: superuser login for {EMAIL} failed ({e}). USER_EMAIL/"
        f"USER_PASSWORD take effect against a VIRGIN data.db only, so a hub "
        f"seeded before they landed carries a random _@b.b superuser instead. "
        f"Repair: {REPAIR}. Role left unchanged.")
    sys.exit(0)

token = (auth or {}).get("token")
if not token:
    log(f"WARN: superuser auth returned no token ({auth!r}) - role left "
        f"unchanged")
    sys.exit(0)

# Authentik login
# PocketBase never returns clientSecret (MarshalJSON blanks it) and an update
# must resend it, so equality cannot be read back. The secret's SHA-256 rides
# in `extra`, which the oidc provider ignores (it reads only issuers and
# jwksURL), and is what makes a rotation visible. Popup flow, so the callback
# is <origin>/api/oauth2-redirect.
sso_secret = os.environ["BESZEL_OIDC_CLIENT_SECRET"]
desired = {
    "name": "oidc",
    "displayName": "Authentik",
    "clientId": SSO_CLIENT_ID,
    "authURL": f"{SSO_ISSUER}/application/o/authorize/",
    "tokenURL": f"{SSO_ISSUER}/application/o/token/",
    "userInfoURL": f"{SSO_ISSUER}/application/o/userinfo/",
    "pkce": True,
    "extra": {"clientSecretSha256": hashlib.sha256(sso_secret.encode()).hexdigest()},
}
def http_error(e):
    body = e.read().decode(errors="replace")[:400] if hasattr(e, "read") else ""
    return f"{e} {body}".strip()


try:
    _, users_collection = call("/api/collections/users", token=token)
except (urllib.error.HTTPError, urllib.error.URLError) as e:
    users_collection = None
    log(f"WARN: could not read the users collection ({http_error(e)}); "
        f"Authentik login left unchanged")
if users_collection is not None:
    oauth2 = users_collection.get("oauth2") or {}
    providers = oauth2.get("providers") or []
    others = sorted(p.get("name") for p in providers if p.get("name") != "oidc")
    current = next((p for p in providers if p.get("name") == "oidc"), None)
    if others:
        # Resending them would need their secrets, which the API never returns.
        log(f"WARN: the users collection has other OAuth2 providers "
            f"({others}); Authentik left unconfigured rather than dropping them")
    elif (oauth2.get("enabled") and current
          and all(current.get(k) == v for k, v in desired.items())):
        log("Authentik OAuth2 provider already configured")
    else:
        # Only `enabled` and `providers`: the body decodes onto the stored
        # collection, so mappedFields and every rule keep their values.
        try:
            call("/api/collections/users", "PATCH",
                 {"oauth2": {"enabled": True,
                             "providers": [{**desired,
                                            "clientSecret": sso_secret}]}},
                 token)
            change(f"{'updated' if current else 'added'} the Authentik OAuth2 "
                   f"provider (client {SSO_CLIENT_ID})")
        except (urllib.error.HTTPError, urllib.error.URLError) as e:
            # PocketBase's validation errors name fields, never values.
            log(f"WARN: PATCH /api/collections/users was refused "
                f"({http_error(e)}); Authentik login left unchanged")

# Server-side filter rather than a client-side scan: PocketBase hides `email`
# on a records list unless the caller is the owner or a superuser, and a filter
# runs against the column either way.
qs = urllib.parse.urlencode({"filter": f'email="{EMAIL}"', "perPage": 1})
_, page = call(f"/api/collections/users/records?{qs}", token=token)
items = (page or {}).get("items") or []
if not items:
    log(f"WARN: no users row for {EMAIL} — the env pair only creates one "
        f"against a virgin data.db. Repair: {REPAIR}, then create the app "
        f"user in the UI. Nothing to promote.")
    sys.exit(0)

record = items[0]
if record.get("role") == "admin":
    log("app user already has role 'admin' - no change")
    sys.exit(0)

call(f"/api/collections/users/records/{record['id']}", "PATCH",
     {"role": "admin"}, token)
change(f"app user {EMAIL} promoted from {record.get('role')!r} to 'admin'")
PY
