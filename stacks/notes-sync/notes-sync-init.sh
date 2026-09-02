#!/bin/sh
# Headless first-run for the notes-sync stack (annex §3).
#
# Two bootstrap shapes:
#   - rmfakecloud has NO provisioning API: the first login CREATES the admin,
#     unauthenticated — this container's real job is to get there first.
#   - Syncthing is configured through a REST API guarded by the sops API key,
#     so it needs no login at all.
#
# Every mutation logs "notes-sync-init: CHANGE: ...". A second run — every
# redeploy reruns this container — must log ZERO change lines.
#
# Python heredoc under /bin/sh: python:3-alpine only, urllib, no requests.
set -eu

python3 - <<'PY'
import json
import os
import sys
import time
import urllib.error
import urllib.request

RM = "http://rmfakecloud:3000"
ST = "http://syncthing:8384"
RMDATA = "/rmdata"


def log(msg):
    print(f"notes-sync-init: {msg}", flush=True)


def fatal(msg):
    print(f"notes-sync-init: FATAL: {msg}", flush=True)
    sys.exit(1)


def env(name):
    v = os.environ.get(name, "").strip()
    if not v:
        # Fail loudly: unset means the .env did not decrypt, and for
        # rmfakecloud "unprovisioned" means the next thing to reach
        # /ui/api/login owns the instance as admin.
        fatal(f"{name} is unset or empty")
    return v


def request(url, *, method="GET", body=None, headers=None, timeout=30):
    data = None
    hdrs = dict(headers or {})
    if body is not None:
        data = json.dumps(body).encode()
        hdrs["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=hdrs, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read().decode().strip()
            return r.status, raw
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode().strip()


def wait_for(url, *, headers=None, tries=60, delay=2):
    for _ in range(tries):
        try:
            code, _body = request(url, headers=headers, timeout=5)
            if code < 500:
                return
        except Exception:
            pass
        time.sleep(delay)
    fatal(f"{url} never answered")


# ---------------------------------------------------------------------------
# rmfakecloud
# ---------------------------------------------------------------------------
# 🚨 The first POST to /ui/api/login on an empty data directory CREATES an
# admin from whatever credentials arrive; no switch closes the window, so
# being first IS the security model (plus the loopback-only publish).
#
# /ui/api/register is deliberately NOT used: gated on RegistrationOpen (bare
# 400 unset) and then on the client IP being literally 127.0.0.1 — which a
# loopback publish cannot satisfy (docker-proxy re-dials from the bridge
# gateway, so the check 403s).
rm_email = env("RMFAKECLOUD_ADMIN_EMAIL")
rm_pass = env("RMFAKECLOUD_ADMIN_PASSWORD")

# 🚨 sanitizeEmail rewrites the identifier ON CREATE ONLY — login looks up
# the RAW string, so any stripped character produces an account that can
# never be logged into, presenting as a bare 401 (observed directly: "stat
# /data/users/rm-admin@test.invalid/.userprofile: no such file" then 401).
# The whitelist `[^a-zA-Z0-9.@-_]+` parses `@-_` as an ASCII RANGE
# (0x40-0x5F = @ A-Z [ \ ] ^ _), so the HYPHEN is stripped — far more common
# in a local part than the '+' upstream discusses. Refuse anything outside
# the real surviving set rather than create an unreachable account.
ALLOWED = set(
    "abcdefghijklmnopqrstuvwxyz"
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    "0123456789"
    ".@[\\]^_"
)
bad = sorted({c for c in rm_email if c not in ALLOWED})
if bad:
    fatal(
        f"RMFAKECLOUD_ADMIN_EMAIL contains {bad!r}, which rmfakecloud strips on "
        f"create but NOT on login ({rm_email!r} would be stored as "
        f"{''.join(c for c in rm_email if c in ALLOWED)!r}). The account would "
        "be unreachable and every login would return a bare 401."
    )

wait_for(f"{RM}/health")

# Pre-check whether this is the creating login, purely so the CHANGE line
# is honest (the user store is a directory of YAML documents).
first_run = None
try:
    users_dir = os.path.join(RMDATA, "users")
    if os.path.isdir(users_dir):
        first_run = not any(os.scandir(users_dir))
    elif os.path.isdir(RMDATA):
        first_run = True
except OSError:
    first_run = None

code, body = request(
    f"{RM}/ui/api/login",
    method="POST",
    body={"email": rm_email, "password": rm_pass},
)
if code != 200:
    fatal(f"rmfakecloud login returned {code}: {body[:400]}")
rm_token = body.strip().strip('"')
if not rm_token:
    fatal("rmfakecloud login returned an empty token")

if first_run is True:
    log(f"CHANGE: created the first rmfakecloud admin ({rm_email})")
elif first_run is False:
    log(f"rmfakecloud admin {rm_email} already exists")
else:
    # Do not guess. A wrong CHANGE line is worse than an honest unknown,
    # because the whole idempotency contract is "a second run prints none".
    log(
        f"rmfakecloud login for {rm_email} succeeded; could not determine "
        f"whether it created the account (unexpected layout under {RMDATA})"
    )

# ---------------------------------------------------------------------------
# Syncthing
# ---------------------------------------------------------------------------
st_key = env("STGUIAPIKEY")
st_headers = {"X-API-Key": st_key}
wait_for(f"{ST}/rest/noauth/health")

code, body = request(f"{ST}/rest/config/options", headers=st_headers)
if code != 200:
    fatal(f"syncthing GET /rest/config/options returned {code}: {body[:400]}")
options = json.loads(body)

# The egress switches + usage reporting: none earns its keep with a tailnet
# address on both ends, and offline they fill the logs with DNS failures.
# urAccepted=-1 = "declined" (a real value, unlike the unset 0).
WANT = {
    "globalAnnounceEnabled": False,
    "relaysEnabled": False,
    "natEnabled": False,
    "localAnnounceEnabled": False,
    "urAccepted": -1,
}
delta = {k: v for k, v in WANT.items() if options.get(k) != v}
if delta:
    code, body = request(
        f"{ST}/rest/config/options",
        method="PATCH",
        body=delta,
        headers=st_headers,
    )
    if code >= 300:
        fatal(f"syncthing PATCH options returned {code}: {body[:400]}")
    log(f"CHANGE: syncthing options {sorted(delta)} set")
else:
    log("syncthing options already as intended")

# The vault folder. `path` is the CONTAINER path; /mnt/fast/vault is bound
# there and pre-owned 1000:1000 by tmpfiles (the image's chown is
# non-recursive and swallows failure — wrongly-owned = healthy container,
# errored folder, no crash).
FOLDER_ID = "vault"
code, body = request(f"{ST}/rest/config/folders", headers=st_headers)
if code != 200:
    fatal(f"syncthing GET /rest/config/folders returned {code}: {body[:400]}")
folders = {f["id"] for f in json.loads(body)}

if FOLDER_ID not in folders:
    code, body = request(
        f"{ST}/rest/config/folders/{FOLDER_ID}",
        method="PUT",
        body={
            "id": FOLDER_ID,
            "label": "vault",
            "path": "/var/syncthing/vault",
            "type": "sendreceive",
            # No devices yet: peers are added by device ID from both sides —
            # an operator step by design. BEP's mutual cert auth is what
            # makes the bare 22000 publish safe; pre-seeding a device here
            # would undercut that.
            "devices": [],
        },
        headers=st_headers,
    )
    if code >= 300:
        fatal(f"syncthing PUT folder returned {code}: {body[:400]}")
    log(f"CHANGE: created syncthing folder '{FOLDER_ID}'")
else:
    log(f"syncthing folder '{FOLDER_ID}' already exists")

log("done")
PY
