#!/bin/sh
# books-init — headless seeding for BOTH library apps. Runs in
# python:3.13-alpine as a oneshot once kavita and audiobookshelf are healthy.
#
# Every mutation logs "books-init: CHANGE: ...". A second run must log ZERO
# change lines; the books suite asserts that. Unset credentials are a hard
# error, so a deploy that raced the decrypt fails loudly instead of leaving
# library apps nobody can log in to.
#
# appsettings.json is Kavita's OIDC channel, not this script — POST
# /api/Settings takes the WHOLE ServerSettingDto, so it is only used for the
# two settings that have no on-disk path, and NEVER for oidcConfig.authority
# (changing it clears every user's OIDC link and needs egress to revalidate).
set -eu

exec python3 - <<'PY'
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

KAVITA = os.environ.get("KAVITA_URL", "http://kavita:5000")
ABS = os.environ.get("ABS_URL", "http://audiobookshelf:80")

changes = 0


def log(msg):
    print(f"books-init: {msg}", flush=True)


def change(msg):
    global changes
    changes += 1
    print(f"books-init: CHANGE: {msg}", flush=True)


def call(url, method="GET", body=None, headers=None, timeout=60):
    """Returns (status, parsed-json-or-raw-text). Raises HTTPError to caller."""
    data = None
    hdrs = dict(headers or {})
    if body is not None:
        data = json.dumps(body).encode()
        hdrs["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=hdrs, method=method)
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


required = ("KAVITA_ADMIN_USER", "KAVITA_ADMIN_PASSWORD",
            "ABS_ADMIN_USER", "ABS_ADMIN_PASSWORD")
missing = [k for k in required if not os.environ.get(k)]
if missing:
    sys.exit(f"books-init: FATAL: unset or empty in .env: {', '.join(missing)} "
             f"(decrypt race?)")

# ===========================================================================
# Kavita
# ===========================================================================
# POST /api/Account/register is anonymous and works exactly once, returning a
# UserDto that already carries the api key.
#
# But a 400 is AMBIGUOUS: Kavita's register handler catches its own
# exceptions, deletes the half-created user and returns 400 too — so a broken
# register looks exactly like an idempotent no-op. The register body is kept
# and reported if the login that follows does not succeed.
kavita_user = {
    "username": os.environ["KAVITA_ADMIN_USER"],
    "password": os.environ["KAVITA_ADMIN_PASSWORD"],
}
api_key = None
try:
    _, dto = call(f"{KAVITA}/api/Account/register", "POST", kavita_user)
    api_key = (dto or {}).get("apiKey")
    change(f"kavita admin {kavita_user['username']} registered")
except urllib.error.HTTPError as e:
    register_body = detail(e)
    if e.code != 400:
        sys.exit(f"books-init: FATAL: kavita register HTTP {e.code}: "
                 f"{register_body}")
    log("kavita admin already registered (or register failed) - trying login")
    try:
        _, dto = call(f"{KAVITA}/api/Account/login", "POST", kavita_user)
        api_key = (dto or {}).get("apiKey")
    except urllib.error.HTTPError as e:
        sys.exit(
            f"books-init: FATAL: kavita register returned 400 AND login then "
            f"failed with HTTP {e.code}.\n"
            f"  register said: {register_body}\n"
            f"  login said:    {detail(e)}\n"
            f"Two causes look identical here. Either an admin exists with "
            f"different credentials (.env changed after the first seed), or "
            f"the register itself ERRORED and Kavita rolled it back — check "
            f"`docker logs kavita` for a stack trace. A KAVITA_TOKEN_KEY "
            f"shorter than 512 bits (64 characters) does exactly that: "
            f"IDX10720 while signing the JWT.")

if not api_key:
    sys.exit("books-init: FATAL: kavita returned no apiKey")

# Auth-key auth is priority 1 in Kavita's handler chain, ahead of JWT, and is
# accepted as the x-api-key header — so no token juggling is needed for the
# admin calls below.
kv_auth = {"x-api-key": api_key}

# POST /api/Library/create takes an UpdateLibraryDto; the full body is sent
# because that is what the schema documents.
#   type 2          = Book; fileGroupTypes [2, 3] = EPub + Pdf (paired with
#                     SUPPORTED_FORMATS in compose.yaml)
#   folderWatching  = false: inotify against a bind mount is unreliable in
#                     Docker, and the post-download hook is a precise trigger.
#   enableMetadata  = TRUE, and the name is a trap: it means "parse the
#                     metadata INSIDE the file", not "fetch from the
#                     internet". False falls back to the FILENAME, which for a
#                     Book library yields an empty Series and indexes NOTHING.
#   allowMetadataMatching / allowScrobbling = false: these are the external
#                     ones, and this stack needs no egress.
#   metadataProvider = 2, REQUIRED even with matching disabled: the enum has
#                     no zero member, so an omitted field binds 0 and 400s. It
#                     selects WHICH provider, not WHETHER.
library = {
    "id": 0,
    "name": "Books",
    "type": 2,
    "folders": ["/books"],
    "metadataProvider": 2,
    "folderWatching": False,
    "includeInDashboard": True,
    "includeInSearch": True,
    "manageCollections": False,
    "manageReadingLists": False,
    "allowScrobbling": False,
    "allowMetadataMatching": False,
    "enableMetadata": True,
    "removePrefixForSortName": False,
    "inheritWebLinksFromFirstChapter": False,
    "fileGroupTypes": [2, 3],
    "excludePatterns": [],
}
# The idempotence guard, rather than creating and reading the 400 back: that
# 400's body is a LOCALIZED message, so a substring match on it would swallow
# unrelated failures. The 400 branch below stays for the race, and this probe
# failing is not fatal — a read-only existence check must never fail a deploy.
#
# Known hole, accepted: renaming the library by hand makes this probe miss and
# a SECOND library gets created over the same folder.
try:
    _, exists = call(
        f"{KAVITA}/api/Library/name-exists"
        f"?name={urllib.parse.quote(library['name'])}", "GET", None, kv_auth)
except (urllib.error.HTTPError, urllib.error.URLError) as e:
    log(f"WARN: name-exists probe unavailable ({e}) - falling back to create")
    exists = False
if exists is True:
    log(f"kavita library {library['name']!r} already exists - no change")
else:
    try:
        call(f"{KAVITA}/api/Library/create", "POST", library, kv_auth)
        change(f"kavita library {library['name']!r} created")
        # Only on creation: a scan on every run would be neither a no-op nor
        # a loggable change, and the post-download hook plus the scheduled
        # scan cover steady state.
        call(f"{KAVITA}/api/Library/scan-all", "POST", None, kv_auth)
        change("kavita initial scan triggered")
    except urllib.error.HTTPError as e:
        body = detail(e)
        if e.code == 400 and "exist" in body.lower():
            log(f"kavita library {library['name']!r} already exists - no change")
        else:
            sys.exit(f"books-init: FATAL: kavita library create HTTP "
                     f"{e.code}: {body}")

# Two DB-only settings, one whole-DTO round trip (GET -> mutate -> POST). The
# masked secret in oidcConfig survives it — the update path recognises the
# asterisk string and restores the stored value.
#
#   allowStatCollection            seeded ON with a daily job; nothing else
#                                  here needs egress.
#   oidcConfig.provisionAccounts   the one OIDC field with no appsettings.json
#                                  path (Seed.SetOidcSettingsFromDisk copies
#                                  exactly Authority/ClientId/Secret/
#                                  CustomScopes), so it is a DB write or
#                                  nothing. Without it OIDC login works and no
#                                  account is ever created.
#
# 🚨 NEVER mutate oidcConfig.authority from here. Both hazards — ClearOidcIds()
# wiping every user's OIDC link, and the discovery-document fetch that cannot
# work offline — live inside `if (currentConfig.Authority != submitted)`.
try:
    _, settings = call(f"{KAVITA}/api/Settings", "GET", None, kv_auth)
    if not isinstance(settings, dict):
        raise ValueError("unexpected settings payload")
    wanted = []
    if "allowStatCollection" not in settings:
        log("kavita settings carry no allowStatCollection key "
            "(renamed upstream?) - skipping")
    elif settings["allowStatCollection"]:
        settings["allowStatCollection"] = False
        wanted.append("anonymous stat collection disabled")
    else:
        log("kavita stat collection already off - no change")

    oidc = settings.get("oidcConfig")
    if not isinstance(oidc, dict):
        log("kavita settings carry no oidcConfig object (renamed upstream?) "
            "- skipping provisionAccounts")
    elif not oidc.get("authority"):
        # OIDC ships READY and OFF: with no client secret kavita-config-init
        # blanks the authority, and flipping a switch on a disabled provider
        # would be a CHANGE line with no effect.
        log("kavita OIDC not configured (empty authority) - leaving "
            "provisionAccounts alone")
    elif not oidc.get("provisionAccounts"):
        oidc["provisionAccounts"] = True
        wanted.append("OIDC provisionAccounts enabled")
    else:
        log("kavita OIDC provisionAccounts already on - no change")

    if wanted:
        call(f"{KAVITA}/api/Settings", "POST", settings, kv_auth)
        for msg in wanted:
            change(f"kavita {msg}")
except (urllib.error.HTTPError, ValueError) as e:
    # Not worth failing a deploy over: it costs one outbound request a day.
    log(f"WARN: could not adjust kavita settings ({e}) - continuing")

# Informational: the URL KOReader's OPDS catalogue entry needs. Every Kavita
# user is created with a system auth key named 'opds', so this exists as soon
# as the admin does.
try:
    _, opds = call(f"{KAVITA}/api/Account/opds-url?authKeyName=opds", "GET",
                   None, kv_auth)
    log(f"kavita OPDS url: {opds}")
except urllib.error.HTTPError as e:
    log(f"WARN: could not read the OPDS url (HTTP {e.code}) - continuing")

# ===========================================================================
# Audiobookshelf
# ===========================================================================
# The isInit guard is not optional: a second POST /init returns 500, and a
# MALFORMED /init body kills the server outright — the route calls
# initializeServer without await or catch, so the TypeError becomes an
# unhandled rejection and the process exits.
try:
    _, status = call(f"{ABS}/status")
except (urllib.error.HTTPError, urllib.error.URLError) as e:
    sys.exit(f"books-init: FATAL: audiobookshelf /status unreachable ({e}) — "
             f"it was healthy enough for compose to start this container, so "
             f"suspect a crash between the two")
if not isinstance(status, dict):
    sys.exit(f"books-init: FATAL: unexpected /status payload: {status!r}")

abs_user = os.environ["ABS_ADMIN_USER"]
abs_password = os.environ["ABS_ADMIN_PASSWORD"]

if not status.get("isInit"):
    # A password that failed to interpolate would create a PASSWORDLESS root
    # user with a 200 response and only a Logger.warn — the emptiness check at
    # the top of this script is what prevents that, and this is the second
    # gate on the same hazard.
    if not abs_password:
        sys.exit("books-init: FATAL: ABS_ADMIN_PASSWORD is empty — "
                 "POST /init would create a passwordless root user")
    try:
        call(f"{ABS}/init", "POST", {"newRoot": {"username": abs_user,
                                                 "password": abs_password}})
    except urllib.error.URLError as e:
        # A connection reset here is not a retry signal: a malformed /init
        # body makes audiobookshelf throw inside an un-awaited handler, which
        # becomes an unhandled rejection and process.exit(1). If this fires,
        # the server is DOWN and re-POSTing will not help.
        sys.exit(f"books-init: FATAL: POST /init failed ({e}) — if this was a "
                 f"connection reset, audiobookshelf has exited; check its "
                 f"logs before retrying")
    change(f"audiobookshelf root user {abs_user} created")
else:
    log("audiobookshelf already initialised - no change")

# user.accessToken, not user.token: the latter is the deprecated non-expiring
# legacy token that the public API docs still recommend. One login per run —
# auth is rate limited to 40 attempts per 10 minutes per client IP.
try:
    _, login = call(f"{ABS}/login", "POST", {"username": abs_user,
                                             "password": abs_password})
except urllib.error.HTTPError as e:
    sys.exit(f"books-init: FATAL: audiobookshelf login HTTP {e.code}: {detail(e)}")

token = ((login or {}).get("user") or {}).get("accessToken")
if not token:
    sys.exit("books-init: FATAL: audiobookshelf login returned no accessToken")
abs_auth = {"Authorization": f"Bearer {token}"}

# /audiobooks is the curated tree; /drop is the media stack's hand-off, and
# registering it as a library FOLDER rather than a staging area is deliberate
# — both mounts are read-only, so nothing could move an item out of a staging
# area anyway, and a book that lands there is playable where it lies.
ABS_FOLDERS = ["/audiobooks", "/drop"]

# Nothing watches the drop directory (disableWatcher below, and the
# post-download hook is shelfmark's), so the library carries a scan cron
# instead. Hourly is the latency between a clean audiobook landing and it
# appearing; a watcher would be immediate at one inotify watch per directory
# across both trees.
ABS_SCAN_CRON = os.environ.get("ABS_AUTOSCAN_CRON", "0 * * * *")

# POST /api/libraries is NOT idempotent — it happily creates a second library
# with the same name — so the list read is the guard.
_, libs = call(f"{ABS}/api/libraries", "GET", None, abs_auth)
existing = [lib for lib in (libs or {}).get("libraries", [])
            if lib.get("name") == "Audiobooks"]
if existing:
    # Reconcile: a deployment seeded before the drop directory existed has a
    # shorter folder list. The PATCH must carry the existing folders WITH
    # their ids — a folder missing from the payload is a removal, and removing
    # one deletes its library items.
    lib = existing[0]
    lib_id = lib.get("id")
    have = {f.get("fullPath"): f for f in (lib.get("folders") or [])}
    missing = [p for p in ABS_FOLDERS if p not in have]
    cron_now = ((lib.get("settings") or {}).get("autoScanCronExpression"))
    payload = {}
    if missing:
        payload["folders"] = (
            [{"id": f["id"], "fullPath": p} for p, f in have.items()]
            + [{"fullPath": p} for p in missing]
        )
    if cron_now != ABS_SCAN_CRON:
        payload["settings"] = dict(lib.get("settings") or {},
                                   autoScanCronExpression=ABS_SCAN_CRON)
    if not payload:
        log("audiobookshelf library 'Audiobooks' already exists - no change")
    else:
        call(f"{ABS}/api/libraries/{lib_id}", "PATCH", payload, abs_auth)
        if missing:
            change(f"audiobookshelf library 'Audiobooks' gained folder(s) "
                   f"{', '.join(missing)}")
            call(f"{ABS}/api/libraries/{lib_id}/scan", "POST", None, abs_auth)
            change("audiobookshelf scan triggered for the new folder(s)")
        if "settings" in payload:
            change(f"audiobookshelf library 'Audiobooks' auto-scan cron set to "
                   f"{ABS_SCAN_CRON!r}")
else:
    # fs.ensureDir() runs on every folder, so this is also the bind-mount
    # permission canary: a nonexistent path under the read-only mount 400s.
    _, created = call(f"{ABS}/api/libraries", "POST", {
        "name": "Audiobooks",
        "mediaType": "book",
        "provider": "audible",
        "folders": [{"fullPath": p} for p in ABS_FOLDERS],
        "settings": {"disableWatcher": True,
                     "autoScanCronExpression": ABS_SCAN_CRON},
    }, abs_auth)
    change("audiobookshelf library 'Audiobooks' created")
    lib_id = (created or {}).get("id")
    if lib_id:
        # Returns 200 BEFORE the scan runs — this only kicks it off.
        call(f"{ABS}/api/libraries/{lib_id}/scan", "POST", None, abs_auth)
        change("audiobookshelf initial scan triggered")

# OIDC is configured only when a secret is present. Empty is the shipping
# state: until the operator lands the VPS-side secret, audiobookshelf runs
# local-auth-only rather than advertising a login button that cannot work.
oidc_secret = os.environ.get("ABS_OIDC_CLIENT_SECRET", "")
if not oidc_secret:
    log("ABS_OIDC_CLIENT_SECRET empty - leaving audiobookshelf on local auth")
else:
    issuer = os.environ.get(
        "ABS_OIDC_ISSUER", "https://auth.idanreed.com/application/o/audiobookshelf/")
    base = issuer.rstrip("/").rsplit("/application/o/", 1)[0]
    slug = issuer.rstrip("/").rsplit("/", 1)[-1]
    external = os.environ.get(
        "ABS_EXTERNAL_URL", "https://audiobookshelf.svc.idanreed.com")
    settings = {
        "authOpenIDIssuerURL": issuer,
        "authOpenIDAuthorizationURL": f"{base}/application/o/authorize/",
        "authOpenIDTokenURL": f"{base}/application/o/token/",
        "authOpenIDUserInfoURL": f"{base}/application/o/userinfo/",
        "authOpenIDJwksURL": f"{base}/application/o/{slug}/jwks/",
        "authOpenIDLogoutURL": f"{base}/application/o/{slug}/end-session/",
        "authOpenIDClientID": os.environ.get("ABS_OIDC_CLIENT_ID",
                                             "audiobookshelf"),
        "authOpenIDClientSecret": oidc_secret,
        "authOpenIDTokenSigningAlgorithm": "RS256",
        # MUST be sent and MUST be "": the default is the literal string
        # `undefined` and the redirect URI interpolates it, so omitting this
        # sends Authentik https://host/undefined/auth/openid/callback and
        # every login dies on a redirect_uri mismatch.
        "authOpenIDSubfolderForRedirectURLs": "",
        "authOpenIDMatchExistingBy": "email",
        "authOpenIDAutoRegister": True,
        # Auto-launch would make …/login/?autoLaunch=0 the only way back to
        # the password login.
        "authOpenIDAutoLaunch": False,
        "authOpenIDButtonText": "Login with Authentik",
        "authOpenIDMobileRedirectURIs": ["audiobookshelf://oauth"],
        # "local" MUST stay: dropping it kills POST /login, which locks out
        # both this script and every break-glass login.
        "authActiveAuthMethods": ["local", "openid"],
    }
    try:
        _, res = call(f"{ABS}/api/auth-settings", "PATCH", settings, abs_auth)
    except urllib.error.HTTPError as e:
        sys.exit(f"books-init: FATAL: audiobookshelf auth-settings HTTP "
                 f"{e.code}: {detail(e)}")
    if (res or {}).get("updated"):
        change("audiobookshelf OIDC configured")
    else:
        log("audiobookshelf OIDC already configured - no change")
    # PATCH returns 200 even for values it rejected, and a missing required
    # field makes the NEXT load silently strip 'openid' from the active
    # methods — so read it back rather than discovering that at first login.
    _, readback = call(f"{ABS}/api/auth-settings", "GET", None, abs_auth)
    applied = (readback or {}).get("authOpenIDSubfolderForRedirectURLs")
    if applied != "":
        sys.exit(f"books-init: FATAL: authOpenIDSubfolderForRedirectURLs came "
                 f"back as {applied!r}, not '' — the redirect_uri would be "
                 f"{external}/{applied}/auth/openid/callback")

log(f"done ({changes} change(s))")
PY
