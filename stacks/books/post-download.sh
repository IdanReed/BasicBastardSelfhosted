#!/bin/sh
# post-download — shelfmark's CUSTOM_SCRIPT hook (annex §3.4). Triggers a
# library scan in whichever app owns the tree the download landed in, so a new
# book shows up in seconds instead of at the next scheduled scan. This is what
# closes the design doc's scan-latency open question.
#
# Upstream's contract, and what it forces:
#   - Invoked once per successful task as `<script> "<target_path>"`, with a
#     versioned JSON document on stdin (CUSTOM_SCRIPT_JSON_PAYLOAD=true).
#   - Runs INSIDE the shelfmark container, so it reaches kavita and
#     audiobookshelf by compose service name on the stack's default network.
#     It could not reach them through the host's loopback-bound published
#     ports (the ntfy/backrest precedent).
#   - A NON-ZERO EXIT MARKS THE DOWNLOAD AS ERROR in the UI. So every failure
#     path here logs and exits 0: a scan that did not fire is a few minutes of
#     latency, while a red "Error" on a file that downloaded perfectly is a
#     lie that sends you looking for a problem that does not exist.
#   - It may run CONCURRENTLY (up to MAX_CONCURRENT_DOWNLOADS), so everything
#     it does must be re-entrant. Both scan endpoints are: Kavita reschedules
#     a concurrent scan rather than erroring, and audiobookshelf's returns
#     immediately regardless.
#   - 300s timeout. Per-request timeouts below are short for that reason.
#
# THIS FILE MUST BE MODE 755 (unlike the other init scripts in the fleet,
# which compose invokes as `/bin/sh <script>` and can stay 644): shelfmark
# execs it directly. If Arcane's gitops sync ever fails to preserve the
# executable bit, the hook stops firing AND — because the exec failure is a
# non-zero result — every completed download is marked Error. The books suite
# invokes it exactly the way shelfmark does, so a lost bit fails a test here
# rather than in production.
#
# Credentials: the admin username/password from the shared .env, which
# shelfmark's container already has (env_file). Nothing is pre-minted and no
# credential file is written — a derived long-lived key would have to be
# rotated, tracked by the drift lint, and stored somewhere both containers can
# read, to buy nothing over a login that costs one request.
set -u

TARGET="${1:-}"

PY=""
for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1; then
        PY="$candidate"
        break
    fi
done
if [ -z "$PY" ]; then
    echo "post-download: no python interpreter on PATH - skipping scan trigger" >&2
    exit 0
fi

# The payload has to be slurped HERE, not in python: the interpreter is fed
# its script on stdin (`python3 - <<'PY'`), so by the time python runs,
# sys.stdin is the heredoc — not shelfmark's JSON document.
#
# Bounded, because `cat` on an inherited-but-never-closed stdin would block
# until shelfmark's 300s hook timeout kills it — and a killed hook is a
# non-zero exit, i.e. a completed download reported as Error. Five seconds is
# far more than a local pipe needs, and argv[1] covers an empty read.
if command -v timeout >/dev/null 2>&1; then
    PAYLOAD="$(timeout 5 cat 2>/dev/null || true)"
else
    PAYLOAD="$(cat 2>/dev/null || true)"
fi
export TARGET PAYLOAD

exec "$PY" - <<'PY'
import json
import os
import sys
import urllib.error
import urllib.request

KAVITA = os.environ.get("KAVITA_URL", "http://kavita:5000")
ABS = os.environ.get("ABS_URL", "http://audiobookshelf:80")
TIMEOUT = 15


def log(msg):
    print(f"post-download: {msg}", flush=True)


def call(url, method="GET", body=None, headers=None):
    data = None
    hdrs = dict(headers or {})
    if body is not None:
        data = json.dumps(body).encode()
        hdrs["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=hdrs, method=method)
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        raw = resp.read().decode(errors="replace")
        try:
            return json.loads(raw) if raw else None
        except ValueError:
            return raw


# The JSON payload's paths.destination is the authoritative answer to "which
# tree did this land in"; argv[1] is the fallback for a payload-less
# invocation (CUSTOM_SCRIPT_JSON_PAYLOAD=false) or a malformed one.
path = os.environ.get("TARGET", "")
try:
    payload = json.loads(os.environ.get("PAYLOAD", ""))
    paths = payload.get("paths") or {}
    path = paths.get("destination") or paths.get("target") or path
except (ValueError, AttributeError):
    pass

if not path:
    log("no target path in argv or stdin - nothing to do")
    sys.exit(0)

audiobook = path.startswith("/audiobooks")
log(f"target {path} -> {'audiobookshelf' if audiobook else 'kavita'}")

try:
    if audiobook:
        user = os.environ.get("ABS_ADMIN_USER", "")
        password = os.environ.get("ABS_ADMIN_PASSWORD", "")
        if not user or not password:
            log("ABS admin credentials absent from the environment - skipping")
            sys.exit(0)
        login = call(f"{ABS}/login", "POST",
                     {"username": user, "password": password})
        token = ((login or {}).get("user") or {}).get("accessToken")
        if not token:
            log("audiobookshelf login returned no accessToken - skipping")
            sys.exit(0)
        auth = {"Authorization": f"Bearer {token}"}
        libs = call(f"{ABS}/api/libraries", "GET", None, auth)
        target = next((lib for lib in (libs or {}).get("libraries", [])
                       if lib.get("name") == "Audiobooks"), None)
        if not target:
            log("no 'Audiobooks' library yet - skipping")
            sys.exit(0)
        call(f"{ABS}/api/libraries/{target['id']}/scan", "POST", None, auth)
        log("audiobookshelf scan triggered")
    else:
        user = os.environ.get("KAVITA_ADMIN_USER", "")
        password = os.environ.get("KAVITA_ADMIN_PASSWORD", "")
        if not user or not password:
            log("kavita admin credentials absent from the environment - skipping")
            sys.exit(0)
        dto = call(f"{KAVITA}/api/Account/login", "POST",
                   {"username": user, "password": password})
        api_key = (dto or {}).get("apiKey")
        if not api_key:
            log("kavita login returned no apiKey - skipping")
            sys.exit(0)
        # scan-all rather than a library id: no id to look up, and the stack
        # has exactly one Kavita library.
        call(f"{KAVITA}/api/Library/scan-all", "POST", None,
             {"x-api-key": api_key})
        log("kavita scan triggered")
except Exception as exc:
    # Deliberately catch EVERYTHING (not just URLError/OSError/ValueError):
    # `call` hands back raw text when a response is not JSON, so a 502 page
    # from a restarting Kavita turns into an AttributeError or KeyError two
    # lines later — which would escape a narrower clause as a traceback, exit
    # 1, and mark a perfectly good download as Error. SystemExit is a
    # BaseException, so the sys.exit(0) calls above still pass through.
    log(f"scan trigger failed ({exc!r}) - the scheduled scan will catch it")

sys.exit(0)
PY
