#!/bin/sh
# cleanuparr-init — the first-run account, the Authentik sign-in, and the
# queue hygiene it exists for: the Radarr/Sonarr and qBittorrent connections,
# the malware blocker and the queue cleaner. Runs in python:3.13-alpine as a
# oneshot once cleanuparr is healthy.
#
# WHY IT WORKS: Cleanuparr has exactly one account. /api/auth/setup/* is
# anonymous until that account exists and is marked complete, and the API
# never requires the wizard's 2FA step. The OIDC settings are columns on the
# same account (PUT /api/account/oidc), so its password login writes them.
# None of it touches the network: Cleanuparr fetches discovery at sign-in,
# so this runs, and Cleanuparr boots, with Authentik down.
#
# Declared state: the account CLEANUPARR_ADMIN_USER with
# CLEANUPARR_ADMIN_PASSWORD, OIDC on against Authentik's cleanuparr-sso
# application (Admin group only), and exclusive mode OFF, so the password stays
# beside it as break-glass. The optional Link Account step (pinning OIDC to one
# Authentik identity) is left to the UI; the PUT never touches it.
#
# Then the connections (the arrs by their compose names with their sops API
# keys, qBittorrent at gluetun:8080 with idan's WebUI login), the malware
# blocker on Cleanuparr's permissive blacklist for both arrs, and the queue
# cleaner (failed imports and stalled downloads); each is commented below.
#
# Secrets are masked on read and cannot be compared — the client secret, the
# arr API keys, the qBittorrent password — so they are written on every run,
# which is also what carries a rotation. Every other mutation logs
# "cleanuparr-init: CHANGE: ..."; a second run must log ZERO.
#
# ⚠ The password is set once, when the account is created. `sopsgen rotate
# user/idan` changes what this init SIGNS IN with, not what Cleanuparr
# stores, and the next run fails loudly: change it under Settings > Account
# first.
set -eu

exec python3 -u - <<'PY'
import json
import os
import sys
import urllib.error
import urllib.request

BASE = os.environ.get("CLEANUPARR_URL", "http://cleanuparr:11011")
CHANGES = 0


def log(msg):
    print(f"cleanuparr-init: {msg}", flush=True)


def change(msg):
    global CHANGES
    CHANGES += 1
    print(f"cleanuparr-init: CHANGE: {msg}", flush=True)


def fatal(msg):
    sys.exit(f"cleanuparr-init: FATAL: {msg}")


def call(path, method="GET", body=None, token=None, timeout=60):
    data = None
    headers = {"Accept": "application/json"}
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"
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


def field(obj, name):
    # The API writes camelCase; read case-insensitively rather than bet on it.
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k.lower() == name.lower():
                return v
    return None


required = ("CLEANUPARR_ADMIN_USER", "CLEANUPARR_ADMIN_PASSWORD",
            "CLEANUPARR_OIDC_ISSUER_URL", "CLEANUPARR_OIDC_CLIENT_ID",
            "CLEANUPARR_OIDC_CLIENT_SECRET", "CLEANUPARR_PUBLIC_URL")
# The connections' credentials are whatever the arrs and qBittorrent were
# seeded with, placeholder-shaped or not: they only have to be there.
connections = ("RADARR__AUTH__APIKEY", "SONARR__AUTH__APIKEY",
               "QBIT_WEBUI_USER", "QBIT_WEBUI_PASSWORD")
missing = [k for k in required + connections if not os.environ.get(k)]
if missing:
    fatal(f"unset or empty: {', '.join(missing)} (decrypt race?)")
placeholder = [k for k in required if os.environ[k].startswith("changeme")]
if placeholder:
    fatal(f"still the changeme placeholder: {', '.join(placeholder)}")

USER = os.environ["CLEANUPARR_ADMIN_USER"]
PASSWORD = os.environ["CLEANUPARR_ADMIN_PASSWORD"]

# 1. The account. While setup is open the first caller to POST it owns the
# instance, so it is claimed here rather than left for a visitor.
_, status = call("/api/auth/status")
if not field(status, "setupCompleted"):
    try:
        call("/api/auth/setup/account", "POST",
             {"username": USER, "password": PASSWORD})
        change(f"created the admin account {USER!r}")
    except urllib.error.HTTPError as e:
        # 409: an account exists but setup was never completed (a run that
        # died between the two calls). Completing it is safe: the login below
        # proves whether it is ours.
        if e.code != 409:
            fatal(f"POST /api/auth/setup/account HTTP {e.code}: {detail(e)} "
                  f"(a 400 here is the password policy: 8-128 characters)")
        log("an unfinished account already exists - completing its setup")
    call("/api/auth/setup/complete", "POST")
    change("first-run setup completed")

# 2. Sign in.
try:
    _, login = call("/api/auth/login", "POST",
                    {"username": USER, "password": PASSWORD})
except urllib.error.HTTPError as e:
    hint = {
        401: "the stored password is not CLEANUPARR_ADMIN_PASSWORD (rotated "
             "user/idan, or the account was claimed by hand): set it under "
             "Settings > Account",
        403: "exclusive mode was turned on in the UI, which disables password "
             "login: turn it off under Settings > Account",
        429: "the account is locked out after failed logins: wait, then rerun",
    }.get(e.code, "unexpected")
    fatal(f"POST /api/auth/login HTTP {e.code}: {detail(e)} ({hint})")
if field(login, "requiresTwoFactor"):
    fatal("2FA was enabled in the UI, which this init cannot answer: disable "
          "it under Settings > Account (Authentik already enforces MFA)")
tokens = field(login, "tokens")
token = field(tokens, "accessToken")
if not token:
    fatal(f"login returned no access token: {str(login)[:200]}")

# 3. The OIDC settings.
want = {
    "enabled": True,
    "providerName": "Authentik",
    "issuerUrl": os.environ["CLEANUPARR_OIDC_ISSUER_URL"],
    "clientId": os.environ["CLEANUPARR_OIDC_CLIENT_ID"],
    "scopes": "openid profile email",
    # The callbacks are this plus /api/auth/oidc/callback and
    # /api/account/oidc/link/callback — the blueprint's redirect URIs.
    "redirectUrl": os.environ["CLEANUPARR_PUBLIC_URL"],
    "exclusiveMode": False,
}
_, have = call("/api/account/oidc", token=token)
drift = sorted(k for k, v in want.items() if field(have, k) != v)
try:
    call("/api/account/oidc", "PUT",
         dict(want, clientSecret=os.environ["CLEANUPARR_OIDC_CLIENT_SECRET"]),
         token=token)
except urllib.error.HTTPError as e:
    fatal(f"PUT /api/account/oidc HTTP {e.code}: {detail(e)}")
if drift:
    change(f"OIDC settings written ({', '.join(drift)})")
else:
    log("OIDC settings unchanged; client secret re-written")



def api(path, method="GET", body=None):
    try:
        return call(path, method, body, token=token)[1]
    except urllib.error.HTTPError as e:
        fatal(f"{method} {path} HTTP {e.code}: {detail(e)}")


def norm(v):
    # URLs come back as normalised Uris (trailing slash); keys are compared
    # case-insensitively at every depth, like field().
    if isinstance(v, dict):
        return {k.lower(): norm(x) for k, x in v.items()}
    if isinstance(v, list):
        return [norm(x) for x in v]
    return v.rstrip("/") if isinstance(v, str) else v


def same(a, b):
    return norm(a) == norm(b)


def drifted(have, want):
    return sorted(k for k, v in want.items() if not same(field(have, k), v))


def configure():
    # 4. The arr connections: the malware blocker and the queue cleaner both
    # work from the arrs' queues. API keys are masked on read, so they are
    # written on every run (which carries a rotation) and never compared.
    for kind, name, url, key, version in (
            ("radarr", "Radarr", "http://radarr:7878", "RADARR__AUTH__APIKEY", 6),
            ("sonarr", "Sonarr", "http://sonarr:8989", "SONARR__AUTH__APIKEY", 4)):
        want = {"enabled": True, "name": name, "url": url, "version": version}
        have = next((i for i in field(api(f"/api/configuration/{kind}"), "instances") or []
                     if field(i, "name") == name), None)
        body = dict(want, apiKey=os.environ[key])
        if have is None:
            api(f"/api/configuration/{kind}/instances", "POST", body)
            change(f"{name} connection added ({url})")
            continue
        api(f"/api/configuration/{kind}/instances/{field(have, 'id')}", "PUT", body)
        drift = drifted(have, want)
        if drift:
            change(f"{name} connection updated ({', '.join(drift)})")
        else:
            log(f"{name} connection unchanged; API key re-written")

    # 5. qBittorrent, at the name the arrs use. The password is masked on
    # read too, so it is written on every run.
    want = {"enabled": True, "name": "qBittorrent", "typeName": "qBittorrent",
            "type": "Torrent", "host": "http://gluetun:8080",
            "username": os.environ["QBIT_WEBUI_USER"]}
    have = next((c for c in field(api("/api/configuration/download_client"), "clients") or []
                 if field(c, "name") == want["name"]), None)
    body = dict(want, password=os.environ["QBIT_WEBUI_PASSWORD"], urlBase="")
    if have is None:
        api("/api/configuration/download_client", "POST", body)
        change(f"qBittorrent download client added ({want['host']})")
    else:
        api(f"/api/configuration/download_client/{field(have, 'id')}", "PUT", body)
        drift = drifted(have, want)
        if drift:
            change(f"qBittorrent download client updated ({', '.join(drift)})")
        else:
            log("qBittorrent download client unchanged; password re-written")

    # 6. The malware blocker, for Radarr and Sonarr downloads: Cleanuparr's
    # permissive blacklist (cleanuparr-blocklist.txt, its blacklist_permissive
    # at the pinned release) — executables, scripts, shortcuts, archives and
    # disk images, while subtitles and audio still download (its stricter list
    # blocks .srt). Matching files are skipped in qBittorrent; a download with
    # nothing left is removed, blocklisted in the arr and searched again.
    # deleteIfAnyFileBlocked stays off, because the list also names .nfo,
    # .txt and .jpg, which nearly every release carries. A local copy under
    # Cleanuparr's /config, so it works offline and changes only with the repo.
    with open("/init/blocklist.txt", "rb") as fh:
        content = fh.read()
    target = "/cleanuparr-config/blocklist.txt"
    try:
        with open(target, "rb") as fh:
            current = fh.read()
    except FileNotFoundError:
        current = None
    if current != content:
        with open(target + ".tmp", "wb") as fh:
            fh.write(content)
        os.chmod(target + ".tmp", 0o644)
        os.replace(target + ".tmp", target)
        change(f"blocklist written to {target} "
               f"({len(content.splitlines())} patterns)")
    blocklist = {"enabled": True, "blocklistType": "Blacklist",
                 "blocklistPath": "/config/blocklist.txt"}
    have = api("/api/configuration/malware_blocker") or {}
    want = {"enabled": True, "radarr": blocklist, "sonarr": blocklist}
    drift = drifted(have, want)
    if drift:
        api("/api/configuration/malware_blocker", "PUT", dict(have, **want))
        change(f"malware blocker on for Radarr and Sonarr ({', '.join(drift)})")
    else:
        log("malware blocker already on - no change")

    # 7. The queue cleaner. A failed import strikes unless the arr's message is
    # about this host rather than the release (a path, the disk, an unpack in
    # progress); three strikes remove, blocklist and re-search. A download
    # stuck fetching metadata, or stalled at 0 B/s, gets five 5-minute runs.
    want = {
        "enabled": True,
        "failedImport": {
            "maxStrikes": 3, "ignorePrivate": False, "deletePrivate": False,
            "skipIfNotFoundInClient": True, "patternMode": "Exclude",
            "patterns": ["is not a valid local path", "Not enough free space",
                         "File is still being unpacked"],
            "changeCategory": False,
        },
        "downloadingMetadataMaxStrikes": 5,
    }
    have = api("/api/configuration/queue_cleaner") or {}
    drift = drifted(have, want)
    if drift:
        api("/api/configuration/queue_cleaner", "PUT", dict(have, **want))
        change(f"queue cleaner on ({', '.join(drift)})")
    else:
        log("queue cleaner already on - no change")

    want = {"name": "Stalled", "enabled": True, "maxStrikes": 5,
            "privacyType": "Public", "minCompletionPercentage": 0,
            "maxCompletionPercentage": 100, "resetStrikesOnProgress": True,
            "minimumProgress": None, "deletePrivateTorrentsFromClient": False,
            "changeCategory": False}
    have = next((r for r in api("/api/queue-rules/stall") or []
                 if field(r, "name") == want["name"]), None)
    if have is None:
        api("/api/queue-rules/stall", "POST", want)
        change("stall rule 'Stalled' added (5 strikes, public torrents)")
    elif drifted(have, want):
        api(f"/api/queue-rules/stall/{field(have, 'id')}", "PUT", want)
        change(f"stall rule 'Stalled' updated ({', '.join(drifted(have, want))})")
    else:
        log("stall rule 'Stalled' unchanged - no change")


# Revoke this run's refresh token whatever happened above, so redeploys do not
# pile up live sessions.
try:
    configure()
finally:
    refresh = field(tokens, "refreshToken")
    if refresh:
        try:
            call("/api/auth/logout", "POST", {"refreshToken": refresh})
        except urllib.error.HTTPError as e:
            log(f"WARN: logout HTTP {e.code}: {detail(e)}")

log(f"done ({CHANGES} change(s))")
PY
