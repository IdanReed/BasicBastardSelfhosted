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
# Every mutation logs "beszel-role: CHANGE:"; a second run must log zero.
# Unset credentials are a hard error (decrypt race); a hub whose superuser is
# not this pair is a WARN with the repair named, never a deploy failure.
set -eu

exec python3 -u - <<'PY'
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

BASE = os.environ.get("BESZEL_URL", "http://beszel:8090")


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


REPAIR = ("docker compose -f /srv/stacks/beszel/compose.yaml -p beszel "
          "run --rm --entrypoint /beszel beszel superuser upsert <email> <pw>")

required = ("USER_EMAIL", "USER_PASSWORD")
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
