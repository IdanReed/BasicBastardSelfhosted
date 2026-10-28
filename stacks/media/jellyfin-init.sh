#!/bin/sh
# jellyfin-init — headless first run: the setup wizard, the first admin and
# the two libraries, then the LDAP plugin's configuration on every run. Runs in
# python:3.13-alpine as a oneshot once jellyfin is healthy.
#
# Everyone but idan signs in through LDAP (the Authentik outpost, stacks/ldap):
# the plugin creates their Jellyfin account at first login, so there is no
# per-user seeding here. idan is the LOCAL admin this script creates, and stays
# local: Jellyfin authenticates an existing account only with the provider it
# was created by, so an LDAP login as `idan` reaches the local password (the
# same IDAN_INITIAL_PASSWORD Authentik holds) and the plugin never creates a
# second idan. That is the break-glass when the VPS is unreachable.
#
# WHY IT WORKS: StartupController and LibraryStructureController both carry
# [Authorize(Policy = FirstTimeSetupOrElevated)], and FirstTimeSetupHandler
# succeeds unconditionally while IsStartupWizardCompleted is false. So the
# whole wizard AND library creation are anonymous over the compose network
# until POST /Startup/Complete closes the window.
#
# 🚨 DO NOT "SIMPLIFY" THIS BY PRE-SEEDING config/system.xml WITH
# IsStartupWizardCompleted=true. JellyfinMigrationService branches on that
# flag: false takes the fresh-install path (setup migrations stamped as
# applied), true takes the UPGRADE path, which runs the network/encoding
# migrations against the seeded XML and rewrites both through a lossy legacy
# schema. Worse, a wizard-completed server with zero users is unrecoverable
# over the API — GET /Startup/User is the ONLY code path that creates the
# first admin, and it is gated behind the wizard being open.
#
# Every mutation logs "jellyfin-init: CHANGE: ..."; a second run — every
# redeploy reruns this — must log ZERO. Unset credentials are a hard error.
set -eu

exec python3 -u - <<'PY'
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = os.environ.get("JELLYFIN_URL", "http://jellyfin:8096")
CHANGES = 0

# Jellyfin requires an Authorization header shaped like this on any
# authenticated call; the token is appended once there is one.
AUTH = ('MediaBrowser Client="jellyfin-init", Device="init", '
        'DeviceId="jellyfin-init", Version="1.0.0"')


def log(msg):
    print(f"jellyfin-init: {msg}", flush=True)


def change(msg):
    global CHANGES
    CHANGES += 1
    print(f"jellyfin-init: CHANGE: {msg}", flush=True)


def call(path, method="GET", body=None, token=None, timeout=120, auth=AUTH):
    data = None
    headers = {"Authorization": auth + (f', Token="{token}"' if token else "")}
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
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


required = ("JELLYFIN_ADMIN_USER", "JELLYFIN_ADMIN_PASSWORD",
            "JELLYFIN_LDAP_BIND_PASSWORD")
missing = [k for k in required if not os.environ.get(k)]
if missing:
    sys.exit(f"jellyfin-init: FATAL: unset or empty in .env: "
             f"{', '.join(missing)} (decrypt race?)")

USER = os.environ["JELLYFIN_ADMIN_USER"]
PASSWORD = os.environ["JELLYFIN_ADMIN_PASSWORD"]
SERVER_NAME = os.environ.get("JELLYFIN_SERVER_NAME", "jellyfin")

# name -> (collectionType, container path). Both live inside the
# /data/media:ro bind and are created by media-init's skeleton pass;
# LibraryManager throws on a path that does not exist. collectionType values
# are lowercase (CollectionTypeOptions is `#pragma`-exempted for that).
LIBRARIES = [
    ("Movies", "movies", "/data/media/movies"),
    ("TV", "tvshows", "/data/media/tv"),
]

# depends_on: service_healthy gates on /health, but the wizard state machine
# needs a moment more after the socket opens.
deadline = time.time() + 300
public = None
while time.time() < deadline:
    try:
        _, public = call("/System/Info/Public")
        if isinstance(public, dict):
            break
    except Exception:  # noqa: BLE001 — anything here means "not yet"
        pass
    time.sleep(5)
if not isinstance(public, dict):
    sys.exit("jellyfin-init: FATAL: /System/Info/Public never answered")

completed = bool(public.get("StartupWizardCompleted"))

# The wizard. Anonymous, and reachable ONLY while it is open.
if not completed:
    # GET (not POST) /Startup/User is what calls UserManager.InitializeAsync()
    # and mints the first admin, named after Environment.UserName; the POST
    # below renames it and sets the password.
    call("/Startup/User")

    call("/Startup/Configuration", "POST", {
        "ServerName": SERVER_NAME,
        "UICulture": "en-US",
        "MetadataCountryCode": "US",
        "PreferredMetadataLanguage": "en",
    })
    change("startup configuration set")

    # 400 "Password must not be empty" if PASSWORD is blank — the guard above
    # is what stops a passwordless admin from ever existing.
    call("/Startup/User", "POST", {"Name": USER, "Password": PASSWORD})
    change(f"admin {USER} created")

    # Tailnet-only behind Caddy, published on loopback. "Remote access" here
    # means "serve requests that did not come from a local subnet", which
    # Caddy's forwarded traffic is. EnableAutomaticPortMapping is [Required]
    # in the DTO even though it is obsolete — and it stays false: no UPnP.
    call("/Startup/RemoteAccess", "POST", {
        "EnableRemoteAccess": True,
        "EnableAutomaticPortMapping": False,
    })
    change("remote access configured (no UPnP)")

# A token. Anonymous while the wizard is open; required once it is closed.
try:
    _, auth = call("/Users/AuthenticateByName", "POST",
                   {"Username": USER, "Pw": PASSWORD})
except urllib.error.HTTPError as e:
    sys.exit(f"jellyfin-init: FATAL: AuthenticateByName HTTP {e.code}: "
             f"{detail(e)} (an admin exists but these credentials do not "
             f"match it — did .env change after the first seed? Jellyfin has "
             f"no headless password reset; reset it in the UI, or delete "
             f"/mnt/fast/jellyfin/config to re-seed)")
token = (auth or {}).get("AccessToken")
if not token:
    sys.exit(f"jellyfin-init: FATAL: AuthenticateByName returned no "
             f"AccessToken: {auth!r}")

# Libraries, reconciled by NAME on every run: a wiped volume rebuilds them and
# a steady state logs nothing.
_, folders = call("/Library/VirtualFolders", token=token)
have = {f.get("Name") for f in (folders or [])}

for name, collection_type, path in LIBRARIES:
    if name in have:
        log(f"library {name!r} already exists - no change")
        continue
    qs = urllib.parse.urlencode({
        "name": name,
        "collectionType": collection_type,
        "paths": path,
        "refreshLibrary": "true",
    })
    try:
        call(f"/Library/VirtualFolders?{qs}", "POST",
             {"LibraryOptions": {
                 "Enabled": True,
                 # inotify against a read-only bind mount is unreliable in
                 # docker; the scheduled scan and refreshLibrary cover it.
                 "EnableRealtimeMonitor": False,
                 "PathInfos": [{"Path": path}],
                 "PreferredMetadataLanguage": "en",
                 "MetadataCountryCode": "US",
             }}, token=token)
    except urllib.error.HTTPError as e:
        sys.exit(f"jellyfin-init: FATAL: creating library {name!r} at {path} "
                 f"HTTP {e.code}: {detail(e)} (LibraryManager throws if the "
                 f"path does not exist — media-init creates the skeleton, so "
                 f"check it ran first)")
    change(f"library {name!r} created ({collection_type} -> {path})")

# Close the wizard LAST: the false->true transition is what queues
# RefreshMediaLibraryTask, so completing before the libraries exist means no
# scan is triggered for them.
if not completed:
    call("/Startup/Complete", "POST", token=token)
    change("startup wizard completed")
else:
    log("startup wizard already completed - no change")

# The LDAP plugin, reconciled on every run. jellyfin-config-init installs it
# before jellyfin starts; its settings live in the plugin's own XML, which also
# holds STATE (LdapUsers, the uid -> Jellyfin user links the plugin writes at
# each first login), so the desired keys are merged into what the API returns
# rather than the file being written whole. Values: jellyfin-ldap.json, which
# must match the blueprint (headscale-vps/authentik/blueprints/custom/
# jellyfin-ldap.yaml); the bind password comes from media.jellyfin-ldap.env.
with open("/init/jellyfin-ldap.json") as fh:
    LDAP = json.load(fh)
want = dict(LDAP["configuration"])
want["LdapBindPassword"] = os.environ["JELLYFIN_LDAP_BIND_PASSWORD"]
guid = LDAP["plugin"]["guid"].replace("-", "").lower()
_, plugins = call("/Plugins", token=token)
plugin = next((p for p in plugins or []
               if str(p.get("Id", "")).replace("-", "").lower() == guid), None)
if plugin is None:
    log("WARN: the LDAP plugin is not loaded - LDAP logins are off until it "
        "installs (jellyfin-config-init downloads it; see its log) and "
        "jellyfin restarts")
elif plugin.get("Status") != "Active":
    log(f"WARN: the LDAP plugin {plugin.get('Version')} is "
        f"{plugin.get('Status')!r}, not Active - LDAP logins are off")
else:
    if plugin.get("Version") != LDAP["plugin"]["version"]:
        log(f"WARN: jellyfin loaded the LDAP plugin {plugin.get('Version')}, "
            f"the pin is {LDAP['plugin']['version']}")
    path = f"/Plugins/{plugin['Id']}/Configuration"
    _, cur = call(path, token=token)
    cur = cur or {}
    drift = sorted(k for k, v in want.items() if cur.get(k) != v)
    if drift:
        merged = dict(cur)
        merged.update(want)
        call(path, "POST", merged, token=token)
        change(f"LDAP plugin configured ({', '.join(drift)})")
    else:
        log("LDAP plugin already configured - no change")

# No OIDC (TV and mobile clients cannot follow the redirect; LDAP above is the
# shared login instead), and jellyfin-config-init removes an earlier SSO-Auth
# install. What that plugin's setup left in the branding — the "Sign in with
# Authentik" form and its CSS — is cleared here. Only that markup is touched:
# a disclaimer set by hand stays.
_, branding = call("/System/Configuration/branding", token=token)
branding = branding or {}
if "/sso/OID/start/" in (branding.get("LoginDisclaimer") or ""):
    branding["LoginDisclaimer"] = ""
    if "a.raised.emby-button" in (branding.get("CustomCss") or ""):
        branding["CustomCss"] = ""
    call("/System/Configuration/branding", "POST", branding, token=token)
    change("login page: removed the Sign in with Authentik button")
else:
    log("no SSO login button - no change")

log(f"done ({CHANGES} change(s))")
PY
