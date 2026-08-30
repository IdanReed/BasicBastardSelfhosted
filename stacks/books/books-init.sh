#!/bin/sh
# books-init — headless seeding for BOTH library apps (annex §3.1/§3.3). Runs
# in python:3.13-alpine as a oneshot once kavita and audiobookshelf are
# healthy.
#
# Contract (media-init pattern):
#   - Every mutation logs "books-init: CHANGE: ...". A second run — every
#     Arcane redeploy reruns this container — must log ZERO change lines. The
#     books suite asserts exactly that.
#   - Unset credentials are a HARD error (decrypt race, finding #11): exiting
#     nonzero fails the deploy loudly instead of leaving library apps nobody
#     can log in to.
#
# What it deliberately does NOT do:
#   - It never touches Kavita's OIDC settings over the API. Three reasons, all
#     from the annex §3.1: POST /api/Settings takes the WHOLE ServerSettingDto
#     (absent fields deserialize to false/null and overwrite live settings);
#     changing oidcConfig.authority clears every user's OIDC link; and the
#     update path validates a changed authority by FETCHING its discovery
#     document, which fails outright with no egress. The authority, client id
#     and secret go through appsettings.json instead, which
#     Seed.SetOidcSettingsFromDisk re-applies at every boot and which bypasses
#     that validation entirely.
#   - It never pre-mints API keys. The post-download hook authenticates with
#     the same admin credentials, which it already has from the shared .env.
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
             f"(decrypt race? finding #11)")

# ===========================================================================
# Kavita
# ===========================================================================
# POST /api/Account/register is [AllowAnonymous] and works exactly once: it
# opens with "if any admin exists, return BadRequest", so 400 is the
# already-seeded signal, not a failure. On success it returns a UserDto that
# already carries the api key — no second call needed.
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
    if e.code != 400:
        sys.exit(f"books-init: FATAL: kavita register HTTP {e.code}: {detail(e)}")
    log("kavita admin already registered - no change")
    try:
        _, dto = call(f"{KAVITA}/api/Account/login", "POST", kavita_user)
        api_key = (dto or {}).get("apiKey")
    except urllib.error.HTTPError as e:
        sys.exit(f"books-init: FATAL: kavita login HTTP {e.code}: {detail(e)} "
                 f"(admin exists but these credentials do not match it — the "
                 f".env changed after the first seed?)")

if not api_key:
    sys.exit("books-init: FATAL: kavita returned no apiKey")

# Auth-key auth is priority 1 in Kavita's handler chain, ahead of JWT, and is
# accepted as the x-api-key header — so no token juggling is needed for the
# admin calls below.
kv_auth = {"x-api-key": api_key}

# POST /api/Library/create takes an UpdateLibraryDto (there is no
# CreateLibraryDto in 0.9.1). Its OpenAPI `required` array lists all of these,
# `id` included, though only some are enforced at runtime — [Required] on a
# non-nullable bool/int is satisfied by false/0, and `id` is never read by
# AddLibrary. The full body is sent anyway: it costs nothing and it is what
# the schema documents.
#   type 2          = Book
#   fileGroupTypes  = [2, 3] = EPub + Pdf (§8.3 if you want EPUB-only)
#   folderWatching  = false: inotify against a bind mount is unreliable in
#                     Docker, and the post-download hook is a precise trigger.
#   allowMetadataMatching / enableMetadata / allowScrobbling = false: they are
#                     the only paths that reach external providers, and this
#                     stack is designed to need no egress.
#   metadataProvider = 2 (Hardcover) is REQUIRED even with matching disabled,
#                     and it is not a formality: MetadataProvider has no zero
#                     member, so an omitted field binds 0, fails the
#                     [EnumDataType] check and gets an automatic 400 — and if
#                     it got past that, ValidateMetadataProvider throws
#                     invalid-metadata-provider, which surfaces as a 500 with
#                     no localized message. It selects WHICH provider would be
#                     used, not WHETHER one is; the two allow* flags above are
#                     what keep it dormant.
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
    "enableMetadata": False,
    "removePrefixForSortName": False,
    "inheritWebLinksFromFirstChapter": False,
    "fileGroupTypes": [2, 3],
    "excludePatterns": [],
}
# GET /api/Library/name-exists is the idempotence guard, rather than creating
# and reading the 400 back: a create that fails for some OTHER reason then
# still surfaces as a failure instead of being swallowed by a substring match
# on the error text (that 400's body is a LOCALIZED message, not the token
# `library-name-exists`, so matching the token would never match). The 400
# branch below stays as belt-and-braces for a race — and as the fallback if
# this probe is unavailable, which is why its failure is not fatal: a
# read-only existence check must never be what fails a deploy.
#
# Known idempotence hole, accepted: renaming the library by hand makes this
# probe miss and the script create a SECOND library over the same folder.
# Keying on the folder instead would be robust, but the name is what the
# create API collides on.
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

# Anonymous usage stats are seeded ON and the job runs daily. Nothing else in
# this stack needs egress, so turn it off — and it is the one setting worth
# the whole-DTO round trip (GET -> mutate -> POST) that the header warns about.
# The masked secret in oidcConfig survives that round trip: the update path
# recognises the asterisk string and restores the stored value.
try:
    _, settings = call(f"{KAVITA}/api/Settings", "GET", None, kv_auth)
    if not isinstance(settings, dict):
        raise ValueError("unexpected settings payload")
    if "allowStatCollection" not in settings:
        log("kavita settings carry no allowStatCollection key "
            "(renamed upstream?) - skipping")
    elif settings["allowStatCollection"]:
        settings["allowStatCollection"] = False
        call(f"{KAVITA}/api/Settings", "POST", settings, kv_auth)
        change("kavita anonymous stat collection disabled")
    else:
        log("kavita stat collection already off - no change")
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
# GET /status is unauthenticated and reports isInit. The guard is not optional:
# a second POST /init returns 500, and a MALFORMED /init body kills the server
# outright — the route calls initializeServer without await and without a
# catch, so the TypeError becomes an unhandled rejection and the process
# handler does Logger.fatal + process.exit(1) (annex §3.3).
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

# POST /api/libraries is NOT idempotent — it happily creates a second library
# with the same name — so the list read is the guard.
_, libs = call(f"{ABS}/api/libraries", "GET", None, abs_auth)
existing = [lib for lib in (libs or {}).get("libraries", [])
            if lib.get("name") == "Audiobooks"]
if existing:
    log("audiobookshelf library 'Audiobooks' already exists - no change")
else:
    # fs.ensureDir() runs on every folder here, which makes this the
    # bind-mount permission canary: a nonexistent path under the read-only
    # mount comes back as a 400.
    #
    # disableWatcher: the recursive watcher takes one inotify watch per
    # directory across the whole tree; the post-download hook triggers scans
    # precisely, so the watcher only buys inotify pressure.
    _, created = call(f"{ABS}/api/libraries", "POST", {
        "name": "Audiobooks",
        "mediaType": "book",
        "provider": "audible",
        "folders": [{"fullPath": "/audiobooks"}],
        "settings": {"disableWatcher": True, "autoScanCronExpression": None},
    }, abs_auth)
    change("audiobookshelf library 'Audiobooks' created")
    lib_id = (created or {}).get("id")
    if lib_id:
        # Returns 200 BEFORE the scan runs — this only kicks it off.
        call(f"{ABS}/api/libraries/{lib_id}/scan", "POST", None, abs_auth)
        change("audiobookshelf initial scan triggered")

# OIDC: configured only when a secret is present. Empty is the shipping state
# (annex §8.4) — the VPS-side client secret needs the production age key, so
# until the operator lands it, audiobookshelf runs local-auth-only rather than
# advertising a login button that cannot work.
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
        # MUST be sent, and MUST be "": the default is the literal string
        # `undefined`, and the redirect URI is built by interpolating it — so
        # omitting this key makes audiobookshelf send Authentik a redirect_uri
        # of https://host/undefined/auth/openid/callback and every login dies
        # on a redirect_uri mismatch (annex §3.3). The settings UI hides this
        # by defaulting the field itself.
        "authOpenIDSubfolderForRedirectURLs": "",
        "authOpenIDMatchExistingBy": "email",
        "authOpenIDAutoRegister": True,
        # Password login stays the default path: auto-launch would make the
        # break-glass route (…/login/?autoLaunch=0) the only way to reach it.
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
    # PATCH returns 200 even for values it rejected (wrong type => Logger.warn
    # + continue), and a missing required field makes ServerSettings.construct
    # silently strip 'openid' from the active methods on the NEXT load. So
    # read it back and say so loudly here rather than discovering it at the
    # first login attempt.
    _, readback = call(f"{ABS}/api/auth-settings", "GET", None, abs_auth)
    applied = (readback or {}).get("authOpenIDSubfolderForRedirectURLs")
    if applied != "":
        sys.exit(f"books-init: FATAL: authOpenIDSubfolderForRedirectURLs came "
                 f"back as {applied!r}, not '' — the redirect_uri would be "
                 f"{external}/{applied}/auth/openid/callback")

log(f"done ({changes} change(s))")
PY
