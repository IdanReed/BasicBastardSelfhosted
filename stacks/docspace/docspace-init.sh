#!/bin/sh
# Headless first-run for OnlyOffice DocSpace (annex §5): drives
# PUT /api/2.0/settings/wizard/complete.
#
# Both things a script would normally lack are handed out by the UNAUTHENTICATED
# GET /api/2.0/settings, because the wizard page needs them before any account
# exists: `wizardToken` (populated only while the wizard is incomplete — which
# is what makes this idempotent for free) and the PBKDF2 `passwordHash` params.
#
# Every mutation logs "docspace-init: CHANGE: ...". A second run — every
# redeploy reruns this container — must log ZERO change lines.
set -eu

python3 - <<'PY'
import binascii
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.request

DS = "http://docspace:80"


def log(msg):
    print(f"docspace-init: {msg}", flush=True)


def fatal(msg):
    print(f"docspace-init: FATAL: {msg}", flush=True)
    sys.exit(1)


def env(name):
    v = os.environ.get(name, "").strip()
    if not v:
        # An unset value means the .env did not decrypt, and an unfinished
        # wizard is reachable by anyone who can reach the port.
        fatal(f"{name} is unset or empty")
    return v


def request(url, *, method="GET", body=None, headers=None, timeout=60):
    data = None
    hdrs = dict(headers or {})
    if body is not None:
        data = json.dumps(body).encode()
        hdrs["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=hdrs, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read().decode(errors="replace").strip()
            return r.status, raw
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace").strip()


def wait_for_settings(tries=120, delay=5):
    for _ in range(tries):
        try:
            code, body = request(f"{DS}/api/2.0/settings", timeout=10)
            if code == 200 and body:
                return json.loads(body)
        except Exception:
            pass
        time.sleep(delay)
    fatal("GET /api/2.0/settings never answered")


email = env("DOCSPACE_ADMIN_EMAIL")
password = env("DOCSPACE_ADMIN_PASSWORD")
if len(password) < 12:
    fatal("DOCSPACE_ADMIN_PASSWORD must be at least 12 characters")

settings = wait_for_settings()
resp = settings.get("response") if isinstance(settings, dict) else None
data = resp if isinstance(resp, dict) else settings

token = (data or {}).get("wizardToken")
if not token:
    # Absence is the idempotency signal, not an error.
    log("wizard already completed - no change")
    log("done")
    sys.exit(0)

# Password hash
# PBKDF2-HMAC-SHA256, salt taken as the UTF-8 BYTES of the salt string (not
# hex-decoded), output as lowercase hex of size/8 bytes. `iterations` is read
# from the response and never hardcoded: upstream's config key is misspelled so
# the value is always the fallback today, but a fix upstream would change it.
ph = (data or {}).get("passwordHash") or {}
try:
    salt = ph["salt"]
    size = int(ph["size"])
    iterations = int(ph["iterations"])
except (KeyError, TypeError, ValueError):
    fatal(f"settings did not carry usable passwordHash parameters: {ph!r}")

# ⚠ With core:password:salt unset the salt is DERIVED FROM THE MACHINE KEY, so
# the stored hash is bound to APP_CORE_MACHINEKEY — which is why that must come
# from sops rather than being auto-generated into the data volume.
digest = hashlib.pbkdf2_hmac(
    "sha256", password.encode("utf-8"), salt.encode("utf-8"), iterations, size // 8
)
password_hash = binascii.hexlify(digest).decode().lower()

code, body = request(
    f"{DS}/api/2.0/settings/wizard/complete",
    method="PUT",
    body={"email": email, "passwordHash": password_hash},
    headers={"confirm": token, "Authorization": token},
)
if code >= 300:
    fatal(f"PUT /api/2.0/settings/wizard/complete returned {code}: {body[:400]}")

log(f"CHANGE: completed the setup wizard as {email}")

# Post-condition: the token must be gone now. If it is not, the wizard did not
# actually complete and the instance is still open to whoever reaches it.
settings = wait_for_settings(tries=12, delay=5)
resp = settings.get("response") if isinstance(settings, dict) else None
data = resp if isinstance(resp, dict) else settings
if (data or {}).get("wizardToken"):
    fatal("the wizard token is still present after completing the wizard")

log("done")
PY
