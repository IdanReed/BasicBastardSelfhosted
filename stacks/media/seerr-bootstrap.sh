#!/bin/sh
# seerr-bootstrap — the three calls a settings.json cannot make, then the
# sign-in settings and the default quality profiles on every run. Runs in
# python:3.13-alpine as a oneshot once seerr is healthy.
#
# THE SHAPE OF THE PROBLEM: public.initialized is a settings-file flag, but the
# admin identity is a ROW in db.sqlite3 (User id 1), and every /api/v1/settings
# route resolves X-Api-Key to that row. So a settings.json that merely says
# initialized:true is a DEAD END — /setup is skipped and /login's Jellyfin form
# posts no serverType, the one field auth.ts requires to create the first user.
# The only door is POST /api/v1/auth/jellyfin, which is unauthenticated and,
# when no admin exists, creates user 1 AND fills the whole jellyfin block from
# the request body.
#
# Idempotent: GET /api/v1/settings/public reports `initialized`, and the
# first-run calls are skipped once it is true. Every mutation logs
# "seerr-bootstrap: CHANGE: ..."; a second run must log ZERO.
set -eu

exec python3 -u - <<'PY'
import json
import os
import sys
import urllib.error
import urllib.request

BASE = os.environ.get("SEERR_URL", "http://seerr:5055")
CHANGES = 0


def log(msg):
    print(f"seerr-bootstrap: {msg}", flush=True)


def change(msg):
    global CHANGES
    CHANGES += 1
    print(f"seerr-bootstrap: CHANGE: {msg}", flush=True)


def call(path, method="GET", body=None, api_key=None, timeout=180):
    data = None
    headers = {}
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    if api_key:
        headers["X-Api-Key"] = api_key
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


required = ("SEERR_API_KEY", "JELLYFIN_ADMIN_USER", "JELLYFIN_ADMIN_PASSWORD")
missing = [k for k in required if not os.environ.get(k)]
if missing:
    sys.exit(f"seerr-bootstrap: FATAL: unset or empty in .env: "
             f"{', '.join(missing)} (decrypt race?)")

API_KEY = os.environ["SEERR_API_KEY"]



def first_run():
    # 1. The admin. UNAUTHENTICATED, and the only route that creates user 1.
    #
    # serverType 2 = Jellyfin (3 = Emby), REQUIRED in the missingAdminUser branch —
    # which is exactly why the /login page's form cannot make the first user.
    # hostname/port/useSsl/urlBase overwrite settings.jellyfin.* wholesale.
    #
    # The credentials are Jellyfin's admin, seeded by jellyfin-init from the same
    # .env: Seerr authenticates against Jellyfin accounts on the stable tag (OIDC
    # lives only in an unreleased preview branch).
    try:
        call("/api/v1/auth/jellyfin", "POST", {
            "username": os.environ["JELLYFIN_ADMIN_USER"],
            "password": os.environ["JELLYFIN_ADMIN_PASSWORD"],
            "email": os.environ.get("SEERR_ADMIN_EMAIL") or "admin@localhost",
            "hostname": os.environ.get("JELLYFIN_HOST") or "jellyfin",
            "port": int(os.environ.get("JELLYFIN_PORT") or 8096),
            "useSsl": False,
            "urlBase": "",
            "serverType": 2,
        })
    except urllib.error.HTTPError as e:
        sys.exit(f"seerr-bootstrap: FATAL: POST /api/v1/auth/jellyfin HTTP "
                 f"{e.code}: {detail(e)} (a 500 'Jellyfin hostname already "
                 f"configured' means settings.jellyfin.ip is non-empty — the seed "
                 f"must leave it ''. Anything else usually means jellyfin-init "
                 f"has not created the admin yet)")
    change("admin user created and jellyfin server linked")

    # 2. Libraries. The ids are Jellyfin ItemIds, unknowable ahead of time, so this
    # syncs the list and enables everything it finds. The API key resolves to user
    # 1, which now exists.
    #
    # TWO calls, not one: ?sync=true with no ?enable sets every library's `enabled`
    # to false, so the enable pass has to follow it.
    ids = []
    try:
        _, libs = call("/api/v1/settings/jellyfin/library?sync=true",
                       api_key=API_KEY)
        ids = [lib["id"] for lib in (libs or [])
               if isinstance(lib, dict) and lib.get("id")]
    except urllib.error.HTTPError as e:
        log(f"WARN: library sync HTTP {e.code}: {detail(e)} - enable them in the "
            f"UI once jellyfin-init has created them")
    if ids:
        call(f"/api/v1/settings/jellyfin/library?enable={','.join(ids)}",
             api_key=API_KEY)
        change(f"enabled {len(ids)} jellyfin librar(ies)")
    else:
        log("WARN: jellyfin reported no libraries - enable them in the UI once "
            "jellyfin-init has created them")

    # 3. Close first-run.
    call("/api/v1/settings/initialize", "POST", api_key=API_KEY)
    change("first-run completed (public.initialized)")


_, public = call("/api/v1/settings/public")
if isinstance(public, dict) and public.get("initialized"):
    log("already initialised - no change")
else:
    first_run()

# Sign-in, on every run: Seerr's users are Jellyfin's, and everyone but idan
# gets a Jellyfin account from the LDAP plugin at their first login. So Jellyfin
# sign-in must stay on (mediaServerLogin), and a Jellyfin user Seerr has never
# imported must be let in and given an account (newPlexLogin — the name is
# Plex's, the setting covers Jellyfin). Both default on; this keeps them on.
SIGN_IN = {"mediaServerLogin": True, "newPlexLogin": True}
_, main = call("/api/v1/settings/main", api_key=API_KEY)
drift = {k: v for k, v in SIGN_IN.items() if (main or {}).get(k) is not v}
if drift:
    call("/api/v1/settings/main", "POST", drift, api_key=API_KEY)
    change(f"sign-in settings set ({', '.join(sorted(drift))})")
else:
    log("Jellyfin sign-in and new-user sign-in already on - no change")

# Default quality profiles, by NAME on every run: media-init keeps only the two
# Efficient profiles in each arr, and Seerr stores a profile by id, which a
# Profilarr re-sync or a rebuilt arr renumbers. A 4K server would take the
# 2160p one. The profile list comes from Seerr's own test call against the
# stored connection, after flushing that arr's cache (Seerr keeps a profile
# list for an hour); a name the arr does not have yet (Sonarr before its first
# Profilarr sync) is a WARN and the default is left alone. The anime profile,
# where one is set, follows the default — unset, Seerr falls back to it anyway.
DEFAULT_PROFILE = {False: "1080p Efficient", True: "2160p Efficient"}
for kind in ("radarr", "sonarr"):
    _, servers = call(f"/api/v1/settings/{kind}", api_key=API_KEY)
    if servers:
        call(f"/api/v1/settings/cache/{kind}/flush", "POST", api_key=API_KEY)
    for srv in servers or []:
        want = DEFAULT_PROFILE[bool(srv.get("is4k"))]
        try:
            _, test = call(f"/api/v1/settings/{kind}/test", "POST", srv,
                           api_key=API_KEY)
        except urllib.error.HTTPError as e:
            log(f"WARN: {kind} {srv.get('name')!r}: could not list its profiles "
                f"(HTTP {e.code}: {detail(e)}) - default profile left as "
                f"{srv.get('activeProfileName')!r}")
            continue
        pid = next((p.get("id") for p in (test or {}).get("profiles") or []
                    if p.get("name") == want), None)
        if pid is None:
            log(f"WARN: {kind} {srv.get('name')!r} has no {want!r} profile yet - "
                f"default profile left as {srv.get('activeProfileName')!r}")
            continue
        new = dict(srv, activeProfileId=pid, activeProfileName=want)
        if srv.get("activeAnimeProfileId") is not None:
            new.update(activeAnimeProfileId=pid, activeAnimeProfileName=want)
        if new == srv:
            log(f"{kind} {srv.get('name')!r} already defaults to {want!r} - no change")
            continue
        # `id` is read-only in Seerr's API schema: a body carrying it is a 400.
        call(f"/api/v1/settings/{kind}/{srv['id']}", "PUT",
             {k: v for k, v in new.items() if k != "id"}, api_key=API_KEY)
        change(f"{kind} {srv.get('name')!r}: default profile "
               f"{srv.get('activeProfileName')!r} -> {want!r} (id {pid})")

log(f"done ({CHANGES} change(s))")
PY
