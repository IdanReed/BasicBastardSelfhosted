#!/bin/sh
# media-init — idempotent, health-gated reconciliation of the media stack's
# inter-service wiring. Runs in python:3.13-alpine as a oneshot.
#
# Contract:
#   - Every mutation logs "media-init: CHANGE: ...". A second run must log
#     ZERO change lines; the media suite asserts exactly that.
#   - Quality profiles: only "1080p Efficient" and "2160p Efficient" are
#     kept — every other profile is deleted once both exist, and an in-use
#     one is a WARN, never fatal. Profilarr still owns their content.
#   - The codec guard rewrites scores, not profiles: AV1 > x265 > x264,
#     strictly, in every profile. A Profilarr sync restores Dictionarry's
#     scores (AV1 at -999999) and the next run re-ranks them, so "no-op on
#     the second run" only holds between Profilarr syncs. GUARD lines in the
#     log are the tell.
#   - Linking Dictionarry needs egress, so a failed link is a WARN with a UI
#     fallback rather than fatal; a linked trash-pcd is fatal.
#   - The Armiger indexer needs the tunnel up (Bitmagnet runs in gluetun's
#     netns) and Bitmagnet's index non-empty; without either it is a WARN and
#     the next run adds it.
set -eu
exec python3 -u - <<'PY'
import json, os, re, sys, time, urllib.error, urllib.parse, urllib.request

CHANGES = 0

def log(kind, msg):
    print(f"media-init: {kind}: {msg}", flush=True)

def change(msg):
    global CHANGES
    CHANGES += 1
    log("CHANGE", msg)

class ApiError(Exception):
    def __init__(self, code, detail):
        super().__init__(f"HTTP {code}: {detail[:200]}")
        self.code = code
        self.detail = detail

def req(method, url, key, body=None, timeout=30):
    data = json.dumps(body).encode() if body is not None else None
    headers = {"X-Api-Key": key}
    if data is not None:
        headers["Content-Type"] = "application/json"
    r = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(r, timeout=timeout) as resp:
            raw = resp.read()
    except urllib.error.HTTPError as e:
        # The response body IS the diagnosis for Servarr validation failures.
        detail = e.read().decode(errors="replace")[:2000]
        log("HTTPERROR", f"{method} {url} -> {e.code}: {detail}")
        raise ApiError(e.code, detail) from None
    return json.loads(raw) if raw else None

def from_schema(schemas, impl, overrides, extra):
    # POST bodies come from the matching /schema entry (nixflix pattern):
    # hand-rolled bodies miss implementation-contract fields and 400.
    tmpl = next(s for s in schemas if s.get("implementation") == impl)
    for f in tmpl.get("fields", []):
        if f.get("name") in overrides:
            f["value"] = overrides[f["name"]]
    tmpl.update(extra)
    return tmpl

def wait_api(name, url, key, deadline=300):
    # Belt over compose's service_healthy: /ping healthy does not guarantee
    # the API-key path is live yet.
    t = time.time() + deadline
    last = None
    while time.time() < t:
        try:
            req("GET", url, key)
            log("OK", f"{name} API answering with the configured key")
            return
        except Exception as e:  # noqa: BLE001 — any failure means "not yet"
            last = e
            time.sleep(5)
    log("FATAL", f"{name} API never answered at {url} ({last})")
    sys.exit(1)

env = os.environ
required = [
    "RADARR__AUTH__APIKEY", "SONARR__AUTH__APIKEY", "PROWLARR__AUTH__APIKEY",
    "PROFILARR_API_KEY", "QBIT_WEBUI_USER", "QBIT_WEBUI_PASSWORD",
]
missing = [k for k in required if not env.get(k)]
if missing:
    # Usually a deploy that raced the first .env decrypt; the next retries.
    sys.exit(f"media-init: FATAL: unset env: {missing} (decrypt race?)")

QBIT_USER = env["QBIT_WEBUI_USER"]
QBIT_PASS = env["QBIT_WEBUI_PASSWORD"]

# ---------------------------------------------------------------------------
# /data skeleton (one filesystem so *arr imports hardlink; owned 1000:1000)
# ---------------------------------------------------------------------------
SKELETON = [
    "media/movies", "media/tv",
    "downloads/movies", "downloads/tv",
    # No *arr imports this one; scan-downloads.sh promotes clean entries to
    # the books drop. Created here so the category save path exists first.
    "downloads/audiobooks",
    "downloads/.incomplete", "downloads/.quarantine",
]
for rel in SKELETON:
    p = os.path.join("/data", rel)
    if not os.path.isdir(p):
        os.makedirs(p, exist_ok=True)
        change(f"created {p}")
for rel in ["media", "downloads"] + SKELETON:
    os.chown(os.path.join("/data", rel), 1000, 1000)  # idempotent, not a CHANGE
log("OK", "/data skeleton present")

# ---------------------------------------------------------------------------
# Radarr / Sonarr: root folder, download client, TRaSH naming
# ---------------------------------------------------------------------------
# TRaSH's naming schemes. The MediaInfo VideoCodec token is what makes the
# codec ranking auditable on disk.
RADARR_NAMING = {
    "renameMovies": True,
    "replaceIllegalCharacters": True,
    "standardMovieFormat": (
        "{Movie CleanTitle} {(Release Year)} {Edition Tags} {[Custom Formats]}"
        "{[Quality Full]}{[MediaInfo VideoDynamicRangeType]}"
        "{[Mediainfo AudioCodec}{ Mediainfo AudioChannels]}"
        "{[MediaInfo VideoCodec]}{-Release Group}"
    ),
    "movieFolderFormat": "{Movie CleanTitle} ({Release Year})",
}
SONARR_EP = (
    " [{Custom Formats }{Quality Full}]{[MediaInfo VideoDynamicRangeType]}"
    "[{MediaInfo VideoBitDepth}bit]{[MediaInfo VideoCodec]}"
    "[{Mediainfo AudioCodec} { Mediainfo AudioChannels}]"
    "{MediaInfo AudioLanguages}{-Release Group}"
)
SONARR_NAMING = {
    "renameEpisodes": True,
    "replaceIllegalCharacters": True,
    "standardEpisodeFormat":
        "{Series TitleYear} - S{season:00}E{episode:00} - {Episode CleanTitle}" + SONARR_EP,
    "dailyEpisodeFormat":
        "{Series TitleYear} - {Air-Date} - {Episode CleanTitle}" + SONARR_EP,
    "seriesFolderFormat": "{Series TitleYear}",
    "seasonFolderFormat": "Season {season:00}",
}

ARRS = {
    "radarr": {
        "base": "http://radarr:7878", "api": "/api/v3",
        "key": env["RADARR__AUTH__APIKEY"],
        "root": "/data/media/movies", "cat_field": "movieCategory",
        "category": "movies", "naming": RADARR_NAMING,
    },
    "sonarr": {
        "base": "http://sonarr:8989", "api": "/api/v3",
        "key": env["SONARR__AUTH__APIKEY"],
        "root": "/data/media/tv", "cat_field": "tvCategory",
        "category": "tv", "naming": SONARR_NAMING,
    },
}

for name, a in ARRS.items():
    base, api, key = a["base"], a["api"], a["key"]
    wait_api(name, f"{base}{api}/system/status", key)

    folders = req("GET", f"{base}{api}/rootfolder", key) or []
    if any(f.get("path") == a["root"] for f in folders):
        log("OK", f"{name}: root folder {a['root']} present")
    else:
        req("POST", f"{base}{api}/rootfolder", key, {"path": a["root"]})
        change(f"{name}: added root folder {a['root']}")

    clients = req("GET", f"{base}{api}/downloadclient", key) or []
    if any(c.get("name") == "qbittorrent" for c in clients):
        log("OK", f"{name}: qbittorrent download client present")
    else:
        # This POST runs a live connection test, and forceSave=true does NOT
        # override severity:error failures — so retry briefly, then WARN.
        body = from_schema(
            req("GET", f"{base}{api}/downloadclient/schema", key),
            "QBittorrent",
            {
                "host": "gluetun", "port": 8080, "useSsl": False,
                "username": QBIT_USER, "password": QBIT_PASS,
                a["cat_field"]: a["category"],
            },
            {
                "name": "qbittorrent", "enable": True, "priority": 1,
                "removeCompletedDownloads": True,
                "removeFailedDownloads": True, "tags": [],
            },
        )
        deadline = time.time() + 120
        while True:
            try:
                req("POST", f"{base}{api}/downloadclient?forceSave=true", key, body)
                change(f"{name}: added qbittorrent download client (gluetun:8080, category {a['category']})")
                break
            except ApiError as e:
                if e.code != 400 or "Unable to connect" not in e.detail:
                    raise
                if time.time() > deadline:
                    log("WARN", f"{name}: qbittorrent unreachable at gluetun:8080 "
                                f"(not started yet? tunnel down keeps it down) — "
                                f"download client NOT configured; the next "
                                f"media-init run reconciles it")
                    break
                time.sleep(5)

    cur = req("GET", f"{base}{api}/config/naming", key)
    merged = dict(cur)
    merged.update(a["naming"])
    if merged == cur:
        log("OK", f"{name}: naming config already TRaSH-style")
    else:
        req("PUT", f"{base}{api}/config/naming/{cur['id']}", key, merged)
        change(f"{name}: naming config set (TRaSH tokens incl. MediaInfo VideoCodec)")

# ---------------------------------------------------------------------------
# qBittorrent: the `audiobooks` category
# ---------------------------------------------------------------------------
# Audiobooks have no *arr, so nothing else creates this category. Over the API
# rather than qBittorrent.conf, which qbit-init only writes when absent — a
# category added there would never reach an existing deployment. Best-effort:
# anything keeping qbit down must WARN, never block the rest.
QBIT = "http://gluetun:8080"
AUDIOBOOK_CATEGORY = "audiobooks"
AUDIOBOOK_SAVE_PATH = "/data/downloads/audiobooks"


def qbit(sid, path, form=None):
    data = urllib.parse.urlencode(form).encode() if form is not None else None
    headers = {}
    if sid:
        headers["Cookie"] = sid
    if data is not None:
        headers["Content-Type"] = "application/x-www-form-urlencoded"
        # A mismatched Origin/Referer is 403'd as cross-site.
        headers["Referer"] = QBIT
    r = urllib.request.Request(
        QBIT + path, data=data, headers=headers,
        method="POST" if data is not None else "GET")
    with urllib.request.urlopen(r, timeout=30) as resp:
        return resp.status, resp.headers, resp.read().decode(errors="replace")


def qbit_login():
    status, hdrs, body = qbit(None, "/api/v2/auth/login",
                              {"username": QBIT_USER, "password": QBIT_PASS})
    # Success is not one shape: 5.2.3 answers 204 with an EMPTY body, older
    # builds 200/"Ok.". Requiring a non-empty body breaks the 5.2.3 case.
    if not (status == 204 or (status == 200 and body.strip() == "Ok.")):
        raise RuntimeError(f"login refused: HTTP {status} {body.strip()[:80]!r}")
    # The cookie is NOT called "SID" — 5.2.3 names it QBT_SID_<port>. Take
    # whatever name=value the server issued rather than looking for a name.
    sid = (hdrs.get("Set-Cookie") or "").split(";")[0].strip()
    # No cookie: qbit skips the session under LocalHostAuth=false. The next
    # call 403s loudly if one was needed after all.
    return sid if "=" in sid else ""


try:
    sid = qbit_login()
    _, _, raw = qbit(sid, "/api/v2/torrents/categories")
    cats = json.loads(raw or "{}")
    cur = cats.get(AUDIOBOOK_CATEGORY)
    if cur is None:
        qbit(sid, "/api/v2/torrents/createCategory",
             {"category": AUDIOBOOK_CATEGORY, "savePath": AUDIOBOOK_SAVE_PATH})
        change(f"qbittorrent: created category {AUDIOBOOK_CATEGORY!r} "
               f"-> {AUDIOBOOK_SAVE_PATH}")
    # rstrip both sides: qbit normalises stored paths, and a returned
    # trailing separator would mean a CHANGE line on every run.
    elif (cur.get("savePath") or "").rstrip("/") != AUDIOBOOK_SAVE_PATH.rstrip("/"):
        qbit(sid, "/api/v2/torrents/editCategory",
             {"category": AUDIOBOOK_CATEGORY, "savePath": AUDIOBOOK_SAVE_PATH})
        change(f"qbittorrent: repointed category {AUDIOBOOK_CATEGORY!r} "
               f"from {cur.get('savePath')!r} to {AUDIOBOOK_SAVE_PATH}")
    else:
        log("OK", f"qbittorrent: category {AUDIOBOOK_CATEGORY!r} already "
                  f"saves to {AUDIOBOOK_SAVE_PATH}")
except Exception as e:  # noqa: BLE001
    log("WARN", f"qbittorrent: could not reconcile the {AUDIOBOOK_CATEGORY!r} "
                f"category ({e}) — audiobook downloads must be assigned it by "
                f"hand until the next media-init run succeeds")

# ---------------------------------------------------------------------------
# qBittorrent: listen on the port forwarded at the provider
# ---------------------------------------------------------------------------
# AirVPN-style forwarding is a port reserved by hand at the provider:
# FIREWALL_VPN_INPUT_PORTS opens it in gluetun's tunnel firewall, and qbit must
# listen on that same port or every inbound peer meets a closed one. Over the
# API, because qbit-init writes qBittorrent.conf only when absent. UPnP and the
# random port stay off — either would move the port off the forwarded one.
fwd = (env.get("FIREWALL_VPN_INPUT_PORTS") or "").split(",")[0].strip()
if not fwd:
    log("OK", "qbittorrent: no forwarded port (FIREWALL_VPN_INPUT_PORTS empty) "
              "- listen port left as is")
elif not fwd.isdigit() or not 1 <= int(fwd) <= 65535:
    log("WARN", f"qbittorrent: FIREWALL_VPN_INPUT_PORTS {fwd!r} is not a port "
                f"- listen port left as is")
else:
    try:
        sid = qbit_login()
        _, _, raw = qbit(sid, "/api/v2/app/preferences")
        prefs = json.loads(raw or "{}")
        want = {"listen_port": int(fwd), "upnp": False, "random_port": False}
        if all(prefs.get(k) == v for k, v in want.items()):
            log("OK", f"qbittorrent: already listening on forwarded port {fwd}")
        else:
            qbit(sid, "/api/v2/app/setPreferences", {"json": json.dumps(want)})
            change(f"qbittorrent: listen port {prefs.get('listen_port')} -> {fwd} "
                   f"(the forwarded port; UPnP and random port off)")
    except Exception as e:  # noqa: BLE001
        log("WARN", f"qbittorrent: could not set the listen port to {fwd} ({e}) "
                    f"- the next media-init run retries")

# ---------------------------------------------------------------------------
# Quality profiles: the two Efficient profiles and nothing else
# ---------------------------------------------------------------------------
# Profilarr syncs Dictionarry's profiles; only the Efficient pair is wanted, so
# every other profile is deleted, which is what leaves Seerr offering just the
# two (seerr-bootstrap points its defaults at them by name). Gated on BOTH
# existing in that arr: before Profilarr's first sync the built-ins are all it
# has. An arr refuses to delete a profile a movie, series, import list or
# collection uses — that one is kept with a WARN; move its items to an
# Efficient profile and the next run deletes it.
KEEP_PROFILES = ("1080p Efficient", "2160p Efficient")
for name, a in ARRS.items():
    base, api, key = a["base"], a["api"], a["key"]
    profiles = req("GET", f"{base}{api}/qualityprofile", key) or []
    missing = [p for p in KEEP_PROFILES if p not in {q.get("name") for q in profiles}]
    if missing:
        log("WARN", f"{name}: no {' or '.join(repr(m) for m in missing)} profile yet "
                    f"(Profilarr has not synced it) - every other profile is kept "
                    f"until both exist")
        continue
    others = [p for p in profiles if p.get("name") not in KEEP_PROFILES]
    for p in others:
        try:
            req("DELETE", f"{base}{api}/qualityprofile/{p['id']}", key)
            change(f"{name}: deleted quality profile {p['name']!r} (only "
                   f"{' and '.join(KEEP_PROFILES)} are offered)")
        except ApiError as e:
            log("WARN", f"{name}: kept quality profile {p['name']!r} - the arr "
                        f"refused to delete it (in use: {e.detail[:160]}); move "
                        f"what uses it to {KEEP_PROFILES[0]!r} and the next run "
                        f"deletes it")
    if not others:
        log("OK", f"{name}: only {' and '.join(KEEP_PROFILES)} exist")

# ---------------------------------------------------------------------------
# Codec ranking: AV1 > x265 > x264, strictly, in every profile
# ---------------------------------------------------------------------------
# A custom format's codec is read from its CONDITIONS, not its name: the
# Dictionarry tiers carry the codec in a required release-title condition
# under names like "1080p Efficient Movie WEB Tier 1" (x265) or "1080p WEB-DL
# (Efficient)" (x264). A condition counts when it is required, not negated,
# matches exactly one codec's tokens, and does not match a codec-free title.
# A format is PLAIN when the codec is all it requires (TRaSH's "x265 (HD)",
# Dictionarry's "AV1"), a TIER when it also requires a resolution, source or
# group. Per profile, with best = the highest-scoring x265 format:
#   1. plain x265 never negative; plain x264 never positive (inverted)
#   2. every x264 format strictly below best
#   3. every AV1 format positive and strictly above best (best + 1)
# x264 TIERS keep a positive score below best: Dictionarry's profiles only
# grab what clears minFormatScore (200000), so a negative x264 tier would make
# every x264-only release — most streaming WEB-DLs — ungrabbable.
CODEC_TOKENS = {
    "av1": ("AV1",),
    "x265": ("x265", "h265", "H.265", "HEVC"),
    "x264": ("x264", "h264", "H.264", "AVC"),
}
CODEC_FREE = "Title 2024 1080p WEB-DL DDP5.1 Atmos-GROUP"


def spec_value(spec):
    for f in spec.get("fields") or []:
        if f.get("name") == "value":
            return f.get("value")
    return None


def codec_of(cf):
    """(codec, plain) for a custom format, or (None, False). Patterns are
    .NET regexes; one Python cannot compile is simply not a codec condition."""
    found, plain = set(), True
    for spec in cf.get("specifications") or []:
        if not spec.get("required") or spec.get("negate"):
            continue
        if spec.get("implementation") != "ReleaseTitleSpecification":
            plain = False
            continue
        try:
            rx = re.compile(str(spec_value(spec) or ""), re.I)
        except re.error:
            plain = False
            continue
        hits = {c for c, toks in CODEC_TOKENS.items()
                if any(rx.search(t) for t in toks)}
        if len(hits) != 1 or rx.search(CODEC_FREE):
            plain = False
            continue
        found |= hits
    return (found.pop(), plain) if len(found) == 1 else (None, False)


def ranking_fixes(prof, codec):
    """Apply the three rules above to one profile's format items in place;
    returns (format name, old score, new score, reason) per change."""
    items = {c: [fi for fi in prof.get("formatItems", [])
                 if codec.get(fi.get("format"), (None,))[0] == c]
             for c in CODEC_TOKENS}
    fixes = []

    def fix(fi, new, why):
        fixes.append((codec[fi["format"]][2], fi.get("score", 0), new, why))
        fi["score"] = new

    for fi in items["x265"]:
        if codec[fi["format"]][1] and fi.get("score", 0) < 0:
            fix(fi, 0, "zeroing: a plain x265 format never scores negative")
    for fi in items["x264"]:
        if codec[fi["format"]][1] and fi.get("score", 0) > 0:
            fix(fi, -fi["score"], "inverting: a plain x264 format never scores positive")
    best = max((fi.get("score", 0) for fi in items["x265"]), default=None)
    if best is not None:
        for fi in items["x264"]:
            if fi.get("score", 0) >= best:
                fix(fi, best - 1, f"x264 must score strictly below the best x265 ({best})")
    floor = max(best or 0, 0)
    for fi in items["av1"]:
        if fi.get("score", 0) <= floor:
            fix(fi, floor + 1, f"AV1 must score above zero and the best x265 ({best})")
    return fixes


for name, a in ARRS.items():
    base, api, key = a["base"], a["api"], a["key"]
    codec = {}
    for cf in req("GET", f"{base}{api}/customformat", key) or []:
        c, plain = codec_of(cf)
        if c:
            codec[cf["id"]] = (c, plain, cf["name"])
    if not codec:
        log("OK", f"{name}: no codec custom formats yet (Profilarr sync will add Dictionarry's)")
        continue
    guarded = False
    for prof in req("GET", f"{base}{api}/qualityprofile", key) or []:
        fixes = ranking_fixes(prof, codec)
        for cf_name, old, new, why in fixes:
            log("GUARD", f"{name}: profile {prof['name']!r} scored {cf_name!r} at "
                         f"{old} - set to {new} ({why})")
        if fixes:
            req("PUT", f"{base}{api}/qualityprofile/{prof['id']}", key, prof)
            change(f"{name}: enforced AV1 > x265 > x264 scoring in profile {prof['name']!r}")
            guarded = True
    if not guarded:
        log("OK", f"{name}: AV1 > x265 > x264 in every profile")

# ---------------------------------------------------------------------------
# Prowlarr -> arr application push-sync
# ---------------------------------------------------------------------------
PROWLARR = "http://prowlarr:9696"
PKEY = env["PROWLARR__AUTH__APIKEY"]
wait_api("prowlarr", f"{PROWLARR}/api/v1/system/status", PKEY)
apps = req("GET", f"{PROWLARR}/api/v1/applications", PKEY) or []
for impl, app in (("Radarr", ARRS["radarr"]), ("Sonarr", ARRS["sonarr"])):
    if any(x.get("implementation") == impl for x in apps):
        log("OK", f"prowlarr: {impl} application present")
        continue
    body = from_schema(
        req("GET", f"{PROWLARR}/api/v1/applications/schema", PKEY),
        impl,
        {"prowlarrUrl": PROWLARR, "baseUrl": app["base"], "apiKey": app["key"]},
        {"name": impl, "syncLevel": "fullSync", "tags": []},
    )
    req("POST", f"{PROWLARR}/api/v1/applications?forceSave=true", PKEY, body)
    change(f"prowlarr: added {impl} application (fullSync — indexers pushed to {app['base']})")

# ---------------------------------------------------------------------------
# Prowlarr: the Armiger indexer (Bitmagnet behind Armiger's filter)
# ---------------------------------------------------------------------------
# A Generic Torznab indexer at Armiger's proxy, never at Bitmagnet directly, so
# every search result passes the filter; Prowlarr's fullSync above pushes it to
# Radarr/Sonarr. Best-effort like the qbit client: bitmagnet/armiger share
# gluetun's netns and are DOWN whenever the tunnel is (WARN, next run adds it).
#
# Prowlarr refuses to save an indexer whose test search returns nothing, and a
# fresh Bitmagnet has an empty index until its crawler's first batch lands —
# and on a first deploy bitmagnet/armiger start only after gluetun is healthy,
# often after this runs. So it waits for Armiger to answer and the index to
# fill, INDEX_WAIT in all; but when neither Armiger nor qbittorrent (same netns)
# answers after TUNNEL_WAIT, the tunnel is down and it gives up at once. Once
# the indexer exists the whole step is a lookup.
ARMIGER = "http://gluetun:8097/torznab"
ARMIGER_NAME = "Armiger (Bitmagnet)"
TUNNEL_WAIT = 120
INDEX_WAIT = 600


def armiger_results():
    """How many items Armiger's proxy returns for an empty search, or None
    when it does not answer at all."""
    try:
        with urllib.request.urlopen(f"{ARMIGER}/api?t=search", timeout=30) as r:
            return r.read().decode(errors="replace").count("<item>")
    except Exception:  # noqa: BLE001 — unreachable is the answer
        return None


def netns_up():
    """Anything answering on qbittorrent's port: gluetun's netns has started
    its tenants, i.e. the tunnel is up."""
    try:
        urllib.request.urlopen(QBIT, timeout=10)
    except urllib.error.HTTPError:
        pass
    except Exception:  # noqa: BLE001
        return False
    return True


indexers = req("GET", f"{PROWLARR}/api/v1/indexer", PKEY) or []
if any(i.get("name") == ARMIGER_NAME for i in indexers):
    log("OK", f"prowlarr: {ARMIGER_NAME} indexer present")
else:
    start = time.time()
    deadline = start + INDEX_WAIT
    n = armiger_results()
    while n is None and time.time() < deadline:
        if time.time() - start > TUNNEL_WAIT and not netns_up():
            break
        time.sleep(15)
        n = armiger_results()
    while n == 0 and time.time() < deadline:
        log("OK", f"prowlarr: Bitmagnet's index is still empty - waiting for "
                  f"its crawler's first batch ({int(deadline - time.time())}s left)")
        time.sleep(30)
        n = armiger_results()
    if n is None:
        log("WARN", f"prowlarr: Armiger does not answer at {ARMIGER} (bitmagnet "
                    f"and armiger run in gluetun's netns, down with the tunnel) "
                    f"- {ARMIGER_NAME} NOT added; the next media-init run adds it")
    elif n == 0:
        log("WARN", f"prowlarr: Bitmagnet's index is still empty after "
                    f"{INDEX_WAIT}s, and Prowlarr refuses an indexer whose test "
                    f"search finds nothing - {ARMIGER_NAME} NOT added; the next "
                    f"media-init run adds it")
    else:
        profiles = req("GET", f"{PROWLARR}/api/v1/appprofile", PKEY) or []
        tmpl = next(i for i in req("GET", f"{PROWLARR}/api/v1/indexer/schema", PKEY)
                    if i.get("implementation") == "Torznab"
                    and i.get("name") == "Generic Torznab")
        for f in tmpl.get("fields", []):
            if f.get("name") == "baseUrl":
                f["value"] = ARMIGER
            elif f.get("name") == "apiPath":
                f["value"] = "/api"
        tmpl.update({
            "name": ARMIGER_NAME, "enable": True, "priority": 25, "tags": [],
            "appProfileId": profiles[0]["id"] if profiles else 1,
        })
        try:
            req("POST", f"{PROWLARR}/api/v1/indexer", PKEY, tmpl, timeout=120)
            change(f"prowlarr: added the {ARMIGER_NAME} indexer ({ARMIGER}, "
                   f"{n} result(s) in its test search)")
        except ApiError as e:
            # Prowlarr's own test search (the body above says why) — the
            # next run retries.
            log("WARN", f"prowlarr: refused {ARMIGER_NAME} ({e}) - the next "
                        f"media-init run retries")

# ---------------------------------------------------------------------------
# Profilarr: Dictionarry database link (best-effort, see header contract)
# ---------------------------------------------------------------------------
PROFILARR = "http://profilarr:6868/api/v1"
PFKEY = env["PROFILARR_API_KEY"]
DICTIONARRY = "https://github.com/Dictionarry-Hub/database"
try:
    dbs = req("GET", f"{PROFILARR}/databases", PFKEY)
    if isinstance(dbs, dict):  # v2 API shape is not pinned down — accept both
        dbs = dbs.get("databases") or dbs.get("items") or []
    def ident(d):
        # IDENTITY fields only. A substring match on the serialised blob
        # hard-failed the whole init on any database whose description or
        # mirror URL merely contained "trash", and read a trash database whose
        # URL mentioned dictionarry as "already linked".
        return " ".join(str(d.get(k) or "") for k in
                        ("name", "repository_url", "repo_url", "url")).lower()

    idents = [ident(d) for d in dbs if isinstance(d, dict)]
    if any("trash" in i for i in idents):
        log("FATAL", "profilarr: a TRaSH-converted database is linked — the codec "
                     "ranking is ENFORCED and trash-pcd reintroduces the x264 bias. Unlink it.")
        sys.exit(1)
    if any("dictionarry" in i for i in idents):
        log("OK", "profilarr: Dictionarry database already linked")
    else:
        try:
            # `repository_url` is the field name v2.2.0 wants.
            req("POST", f"{PROFILARR}/databases", PFKEY,
                {"name": "Dictionarry", "repository_url": DICTIONARRY},
                timeout=120)
            change("profilarr: linked the Dictionarry database (the ONLY allowed source)")
        except Exception as e:  # noqa: BLE001
            log("WARN", f"profilarr: could not link Dictionarry automatically ({e}). "
                        f"Needs egress (git clone) — one-time UI fallback: "
                        f"Databases -> Add -> {DICTIONARRY}")
except SystemExit:
    raise
except Exception as e:  # noqa: BLE001
    log("WARN", f"profilarr: API not reachable/compatible ({e}); link the "
                f"Dictionarry database via the UI (never trash-pcd)")

print(f"media-init: complete: {CHANGES} change(s)", flush=True)
PY
