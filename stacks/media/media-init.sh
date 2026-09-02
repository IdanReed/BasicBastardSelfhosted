#!/bin/sh
# media-init — idempotent, health-gated reconciliation of the media stack's
# inter-service wiring (annex §6, nixflix pattern: keys pushed down via env,
# a oneshot does the rest over REST — no UI clicks). Runs in
# python:3.13-alpine (see compose.yaml for why not curl+jq).
#
# Contract:
#   - Every mutation logs "media-init: CHANGE: ...". A second run must log
#     ZERO change lines — the idempotence property the media suite asserts.
#   - x265 GUARD (x265/H265 ENFORCED — LONGRUN rule), BOTH sides of the bias,
#     per quality profile: (a) any CF matching /x265|h.?265|hevc/i with a
#     NEGATIVE score is zeroed (inverts TRaSH's "x265 (HD) at -10000" golden
#     rule); (b) any CF matching /x264|h.?264|\bavc\b/i with a POSITIVE
#     score is INVERTED — rewarding x264 defeats the policy as effectively
#     as punishing x265; (c) with both kinds present, the best x265 score
#     must STRICTLY outrank the best x264 (ties demoted). Profilarr owns the
#     profiles; the guard only stops x264-biased scoring.
#     Deliberate consequences of (b): under the arrs' default minFormatScore
#     of 0 an inverted x264 CF makes x264-only releases un-grabbable — no
#     x264 fallback tier. And a legitimately-positive synced x264 CF churns
#     forever (Profilarr sync restores, guard re-inverts): "second run is a
#     no-op" only holds between syncs; GUARD log lines are the tell.
#   - Profilarr: links the Dictionarry database (the ONLY allowed source);
#     hard-fails if trash-pcd is ever linked. Linking needs egress, so a
#     failed link is a loud WARN with the UI fallback, not fatal — the
#     offline suite runs without egress.
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
    # Usually the deploy raced the first .env decrypt (finding #11's residual
    # window) — fail loudly, the next redeploy retries.
    sys.exit(f"media-init: FATAL: unset env: {missing} (decrypt race? see finding #11)")

QBIT_USER = env["QBIT_WEBUI_USER"]
QBIT_PASS = env["QBIT_WEBUI_PASSWORD"]

# ---------------------------------------------------------------------------
# /data skeleton (hardlink-friendly single-filesystem layout, owned 1000:1000)
# ---------------------------------------------------------------------------
SKELETON = [
    "media/movies", "media/tv",
    "downloads/movies", "downloads/tv",
    # Audiobook category dir — nothing *arr-shaped imports it;
    # scan-downloads.sh promotes clean entries to the books drop (Option C,
    # ServerNotes/designs/audiobook-acquisition.md). Created here so the
    # category save path exists before the first torrent lands.
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
# TRaSH's recommended naming schemes — codec-neutral; the MediaInfo
# VideoCodec/VideoDynamicRangeType tokens make the x265 policy auditable on
# disk (annex §2).
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
        # This POST runs a live connection test and forceSave=true does NOT
        # override severity:error failures (proven by the media suite,
        # contra the Servarr lore). qbit's WebUI answers even with the
        # tunnel down, but only once the container is up — retry briefly,
        # then degrade to a loud WARN the next media-init run reconciles.
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
# qBittorrent: the `audiobooks` category (Option C acquisition path)
# ---------------------------------------------------------------------------
# Radarr/Sonarr create their own categories via the download-client config;
# nothing creates this one (audiobooks have no *arr), and scan-downloads.sh
# promotes clean entries OUT of its save path. Over the API, NOT
# qBittorrent.conf: qbit-init only writes that file when absent, so a
# category added there would never reach an existing deployment.
# Best-effort like the download-client POST: anything keeping qbit from
# starting must be a WARN the next run reconciles, never a failure that
# blocks the rest.
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
        # A MISMATCHED Origin/Referer is 403'd as cross-site; absent is fine,
        # but sending the right one costs nothing.
        headers["Referer"] = QBIT
    r = urllib.request.Request(
        QBIT + path, data=data, headers=headers,
        method="POST" if data is not None else "GET")
    with urllib.request.urlopen(r, timeout=30) as resp:
        return resp.status, resp.headers, resp.read().decode(errors="replace")


try:
    status, hdrs, body = qbit(None, "/api/v2/auth/login",
                              {"username": QBIT_USER, "password": QBIT_PASS})
    # SUCCESS IS NOT ONE SHAPE. qBittorrent 5.2.3 answers 204 with an EMPTY
    # body (the media suite pins exactly that); older builds 200/"Ok.".
    # Wrong password = 401 (urlopen raises). Do NOT require a non-empty
    # body — that once turned a successful login into a permanent WARN.
    if not (status == 204 or (status == 200 and body.strip() == "Ok.")):
        raise RuntimeError(f"login refused: HTTP {status} {body.strip()[:80]!r}")
    # 🚨 THE COOKIE IS NOT CALLED "SID". 5.2.3 names it QBT_SID_<WebUI port>
    # (QBT_SID_8080 here) — checking for "SID" (as every API snippet online
    # says) finds nothing, sends no cookie, and 403s the next call. Take
    # whatever name=value the server issued.
    sid = (hdrs.get("Set-Cookie") or "").split(";")[0].strip()
    if "=" not in sid:
        # No cookie: qbit skips the session when auth is not needed
        # (WebUI\LocalHostAuth=false, local source). Carry on; the next call
        # 403s loudly if it was needed.
        sid = ""

    _, _, raw = qbit(sid, "/api/v2/torrents/categories")
    cats = json.loads(raw or "{}")
    cur = cats.get(AUDIOBOOK_CATEGORY)
    if cur is None:
        qbit(sid, "/api/v2/torrents/createCategory",
             {"category": AUDIOBOOK_CATEGORY, "savePath": AUDIOBOOK_SAVE_PATH})
        change(f"qbittorrent: created category {AUDIOBOOK_CATEGORY!r} "
               f"-> {AUDIOBOOK_SAVE_PATH}")
    # rstrip("/") both sides: qbit normalises stored paths; a returned
    # trailing separator would mean an editCategory — a CHANGE line — every
    # run, breaking the idempotence contract the suite asserts.
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
# x265 scoring guard, both-sided (see header contract)
# ---------------------------------------------------------------------------
X265 = re.compile(r"x265|h\.?265|hevc", re.I)
X264 = re.compile(r"x264|h\.?264|\bavc\b", re.I)
for name, a in ARRS.items():
    base, api, key = a["base"], a["api"], a["key"]
    cfs = req("GET", f"{base}{api}/customformat", key) or []
    f265 = {cf["id"]: cf["name"] for cf in cfs if X265.search(cf.get("name", ""))}
    # A name matching both regexes counts as x265, so the two rules cannot
    # fight over one item.
    f264 = {cf["id"]: cf["name"] for cf in cfs
            if X264.search(cf.get("name", "")) and cf["id"] not in f265}
    if not (f265 or f264):
        log("OK", f"{name}: no codec custom formats yet (Profilarr sync will add Dictionarry's)")
        continue
    guarded = False
    for prof in req("GET", f"{base}{api}/qualityprofile", key) or []:
        dirty = False
        for fi in prof.get("formatItems", []):
            score = fi.get("score", 0)
            if fi.get("format") in f265 and score < 0:
                log("GUARD", f"{name}: profile {prof['name']!r} scored "
                             f"{f265[fi['format']]!r} at {score} — zeroing (x265 ENFORCED)")
                fi["score"] = 0
                dirty = True
            elif fi.get("format") in f264 and score > 0:
                log("GUARD", f"{name}: profile {prof['name']!r} scored "
                             f"{f264[fi['format']]!r} at +{score} — inverting to "
                             f"{-score} (x265 ENFORCED: x264 must never score positive)")
                fi["score"] = -score
                dirty = True
        # Strictness: after the rules above x265 >= 0 >= x264, so the only
        # possible tie is both at 0; demote the tied x264 items to -1.
        i265 = [fi for fi in prof.get("formatItems", []) if fi.get("format") in f265]
        i264 = [fi for fi in prof.get("formatItems", []) if fi.get("format") in f264]
        if i265 and i264:
            best265 = max(fi.get("score", 0) for fi in i265)
            for fi in i264:
                if fi.get("score", 0) >= best265:
                    log("GUARD", f"{name}: profile {prof['name']!r} ties "
                                 f"{f264[fi['format']]!r} at {fi.get('score', 0)} with the "
                                 f"best x265 score — demoting to {best265 - 1} "
                                 f"(x265 must STRICTLY outrank x264)")
                    fi["score"] = best265 - 1
                    dirty = True
        if dirty:
            req("PUT", f"{base}{api}/qualityprofile/{prof['id']}", key, prof)
            change(f"{name}: enforced x265-over-x264 scoring in profile {prof['name']!r}")
            guarded = True
    if not guarded:
        log("OK", f"{name}: x265 outranks x264 in every profile (no negative "
                  f"x265, no positive x264, no ties)")

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
# Profilarr: Dictionarry database link (best-effort, see header contract)
# ---------------------------------------------------------------------------
PROFILARR = "http://profilarr:6868/api/v1"
PFKEY = env["PROFILARR_API_KEY"]
DICTIONARRY = "https://github.com/Dictionarry-Hub/database"
try:
    dbs = req("GET", f"{PROFILARR}/databases", PFKEY)
    if isinstance(dbs, dict):  # v2 API shape is not pinned down — accept both
        dbs = dbs.get("databases") or dbs.get("items") or []
    blob = json.dumps(dbs).lower()
    if "trash" in blob:
        log("FATAL", "profilarr: a TRaSH-converted database is linked — x265 is "
                     "ENFORCED and trash-pcd reintroduces the x264 bias. Unlink it.")
        sys.exit(1)
    if "dictionarry" in blob:
        log("OK", "profilarr: Dictionarry database already linked")
    else:
        try:
            # repository_url verified against v2.2.0 (its validation error
            # names it; a live POST succeeds). With egress profilarr may
            # pre-link Dictionarry on first boot — the "already linked"
            # branch catches that.
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
