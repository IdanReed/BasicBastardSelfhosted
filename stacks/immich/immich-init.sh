#!/bin/sh
# immich-init — headless admin seeding (annex §3 "Admin seeding"). Runs in
# python:3.13-alpine as a oneshot after immich-server is healthy.
#
# Immich's first-user flow is POST /api/auth/admin-sign-up: unauthenticated,
# works exactly once, no wizard. Contract (media-init pattern):
#   - The one mutation logs "immich-init: CHANGE: ...". A second run — every
#     redeploy reruns this container — must log ZERO change lines: "already
#     onboarded" responses are success, not failure.
#   - Unset credentials are a HARD error (decrypt race, finding #11): exiting
#     nonzero fails the deploy loudly instead of leaving a server nobody can
#     log in to.
#
# v3-isms (annex §0): this is the only seeding done in production. API keys
# are NOT pre-minted (POST /api/api-keys needs a `permissions` array in v3;
# the suite mints its own per run). OIDC users auto-register as non-admin on
# first login; seeding IMMICH_ADMIN_EMAIL as your Authentik email makes the
# OIDC identity merge into this admin (annex §4 / open question §8.4).
#
# Lives in a file (mounted read-only, delivered by the stack git sync)
# rather than inline in compose.yaml: python needs no $-escaping here and
# the script stays runnable/reviewable on its own.
set -eu

exec python3 - <<'PY'
import json
import os
import sys
import urllib.error
import urllib.request

BASE = os.environ.get("IMMICH_URL", "http://immich-server:2283")

missing = [k for k in ("IMMICH_ADMIN_EMAIL", "IMMICH_ADMIN_NAME",
                       "IMMICH_ADMIN_PASSWORD") if not os.environ.get(k)]
if missing:
    sys.exit(f"immich-init: FATAL: unset in .env: {', '.join(missing)} "
             f"(decrypt race? finding #11)")

body = json.dumps({
    "email": os.environ["IMMICH_ADMIN_EMAIL"],
    "name": os.environ["IMMICH_ADMIN_NAME"],
    "password": os.environ["IMMICH_ADMIN_PASSWORD"],
}).encode()

req = urllib.request.Request(
    BASE + "/api/auth/admin-sign-up",
    data=body,
    headers={"Content-Type": "application/json"},
)
try:
    with urllib.request.urlopen(req, timeout=30) as resp:
        print(f"immich-init: CHANGE: admin "
              f"{os.environ['IMMICH_ADMIN_EMAIL']} seeded (HTTP {resp.status})")
except urllib.error.HTTPError as e:
    detail = e.read().decode(errors="replace")[:500]
    # 400 is what v3 returns once an admin exists ("The server already has an
    # admin"); tolerate 409 too in case a future version reclassifies it.
    # Anything else (401 secure-request policy, 500, validation) is real.
    if e.code in (400, 409) and "admin" in detail.lower():
        print(f"immich-init: admin already onboarded (HTTP {e.code}) - no change")
    else:
        sys.exit(f"immich-init: FATAL: admin-sign-up HTTP {e.code}: {detail}")
PY
