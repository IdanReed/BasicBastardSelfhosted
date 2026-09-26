#!/bin/sh
# jellyfin-init — headless first run: the setup wizard, the first admin, and
# the two libraries. Runs in python:3.13-alpine as a oneshot once jellyfin is
# healthy.
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


def call(path, method="GET", body=None, token=None, timeout=120):
    data = None
    headers = {"Authorization": AUTH + (f', Token="{token}"' if token else "")}
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


required = ("JELLYFIN_ADMIN_USER", "JELLYFIN_ADMIN_PASSWORD")
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

# SSO-Auth plugin (installed by jellyfin-config-init) — the "authentik"
# provider plus the login-page button. Best-effort like the install: a missing
# plugin or an empty secret leaves jellyfin on local logins, never fails the
# init (seerr-bootstrap gates on this exiting 0).
PROVIDER = os.environ.get("JELLYFIN_SSO_PROVIDER", "authentik")
OIDC_SECRET = os.environ.get("JELLYFIN_OIDC_CLIENT_SECRET", "")
PUBLIC_URL = os.environ.get("JELLYFIN_PUBLIC_URL", "").rstrip("/")

# Managed keys only; anything else in the stored config (CanonicalLinks — the
# SSO-name -> user-id map) is carried over, because OID/Add REPLACES the whole
# provider entry.
SSO_CONFIG = {
    "OidEndpoint": os.environ.get("JELLYFIN_OIDC_ENDPOINT", ""),
    "OidClientId": os.environ.get("JELLYFIN_OIDC_CLIENT_ID", ""),
    "OidSecret": OIDC_SECRET,
    "Enabled": True,
    # preferred_username is the Authentik username, so the `idan` login lands
    # on the admin this script created (the plugin matches existing users by
    # name). Changing it orphans every linked account.
    "DefaultUsernameClaim": "preferred_username",
    # Recomputed on every SSO login from the `groups` claim (profile scope):
    # members of Admin are admins, headscale-users may log in at all.
    "EnableAuthorization": True,
    "RoleClaim": "groups",
    "AdminRoles": ["Admin"],
    "Roles": ["headscale-users"],
    "EnableAllFolders": True,
    "EnabledFolders": [],
    "EnableFolderRoles": False,
    "EnableLiveTv": False,
    "EnableLiveTvManagement": False,
    # The plugin prepends "openid profile"; null here renders empty scopes.
    "OidScopes": ["email"],
    # Behind Caddy jellyfin sees http; the callback must be https to match the
    # blueprint's strict redirect_uri.
    "SchemeOverride": "https",
    # EMPTY on purpose: a DefaultProvider switches each SSO user's password
    # provider, which would lock this script and seerr-bootstrap out of the
    # admin's password login.
    "DefaultProvider": "",
}

BUTTON = (
    f'<form action="{PUBLIC_URL}/sso/OID/start/{PROVIDER}">'
    '<button class="raised block emby-button button-submit">'
    "Sign in with Authentik</button></form>"
)
BUTTON_CSS = (
    "a.raised.emby-button { padding: 0.9em 1em; color: inherit !important; }\n"
    ".disclaimerContainer { display: block; }"
)


def lower_keys(d):
    return {str(k).lower(): v for k, v in (d or {}).items()}


def same(a, b):
    # The plugin round-trips "" and [] as null; treat all three as unset.
    return (a if a not in ("", []) else None) == (b if b not in ("", []) else None)


_, plugins = call("/Plugins", token=token)
sso = next((p for p in (plugins or []) if p.get("Name") == "SSO Authentication"),
           None)
if not OIDC_SECRET:
    log("JELLYFIN_OIDC_CLIENT_SECRET empty - leaving SSO unconfigured")
elif sso is None or sso.get("Status") != "Active":
    log(f"WARN: SSO-Auth plugin not active ({sso and sso.get('Status')!r}) - "
        f"see jellyfin-config-init; leaving SSO unconfigured")
else:
    _, stored = call("/sso/OID/Get", token=token)
    current = lower_keys((stored or {}).get(PROVIDER))
    want = lower_keys(SSO_CONFIG)
    if all(same(current.get(k), v) for k, v in want.items()):
        log(f"SSO provider {PROVIDER!r} already configured - no change")
    else:
        body = dict(SSO_CONFIG)
        if current.get("canonicallinks"):
            body["CanonicalLinks"] = current["canonicallinks"]
        try:
            call(f"/sso/OID/Add/{PROVIDER}", "POST", body, token=token)
        except urllib.error.HTTPError as e:
            sys.exit(f"jellyfin-init: FATAL: SSO OID/Add HTTP {e.code}: "
                     f"{detail(e)}")
        change(f"SSO provider {PROVIDER!r} configured "
               f"({SSO_CONFIG['OidEndpoint']})")

    _, branding = call("/System/Configuration/branding", token=token)
    branding = branding or {}
    if (branding.get("LoginDisclaimer") == BUTTON
            and branding.get("CustomCss") == BUTTON_CSS):
        log("login button already set - no change")
    else:
        branding["LoginDisclaimer"] = BUTTON
        branding["CustomCss"] = BUTTON_CSS
        call("/System/Configuration/branding", "POST", branding, token=token)
        change("login page: Sign in with Authentik button")

log(f"done ({CHANGES} change(s))")
PY
