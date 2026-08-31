#!/bin/sh
# Headless first-run for OnlyOffice DocSpace (annex §5).
#
# DocSpace ships a browser setup wizard, and behind it a real API:
#     PUT /api/2.0/settings/wizard/complete
# guarded by [Authorize(AuthenticationSchemes = "confirm", Roles = "Wizard")].
#
# The two things that would normally make that unusable from a script are both
# handed out by the UNAUTHENTICATED `GET /api/2.0/settings`, because the wizard
# page needs them before any account exists:
#   - wizardToken   — populated ONLY while WizardSettings.Completed is false
#   - passwordHash  — the PBKDF2 {size, iterations, salt} the client must use
#
# That first one makes this idempotent for free: no token means the wizard is
# already done, so the script logs no change and exits 0.
#
# Every mutation logs "docspace-init: CHANGE: ...". A second run — and every
# Arcane redeploy reruns this container — must log ZERO change lines.
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
        # Fail loudly. An unset value means the .env did not decrypt, and an
        # unfinished wizard is reachable by anyone who can reach the port.
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
    # The token exists only while the wizard is incomplete, so its absence is
    # the idempotency signal — not an error.
    log("wizard already completed - no change")
    log("done")
    sys.exit(0)

# ---------------------------------------------------------------------------
# The password hash
# ---------------------------------------------------------------------------
# PBKDF2, HMAC-SHA256, with the salt taken as the UTF-8 BYTES OF THE SALT
# STRING (not hex-decoded), and the output as lowercase hex of Size/8 bytes.
#
# ⚠ READ `iterations` FROM THE RESPONSE; never hardcode it. Upstream's
# PasswordHasher reads the iteration count with a DOTTED configuration key
# ("core.password.iterations") while its neighbours use colons — ASP.NET keys
# are colon-delimited, so that key can never resolve and the value is always
# the 100000 fallback. Harmless today, but a future upstream fix would change
# it, and a hardcoded 100000 would then silently produce a hash that no longer
# matches.
ph = (data or {}).get("passwordHash") or {}
try:
    salt = ph["salt"]
    size = int(ph["size"])
    iterations = int(ph["iterations"])
except (KeyError, TypeError, ValueError):
    fatal(f"settings did not carry usable passwordHash parameters: {ph!r}")

# ⚠ If core:password:salt is unset, the salt is DERIVED FROM THE MACHINE KEY.
# So the stored hash is bound to APP_CORE_MACHINEKEY: change that and every
# password stops matching. This is why the machine key must come from sops
# rather than being auto-generated into the data volume.
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
