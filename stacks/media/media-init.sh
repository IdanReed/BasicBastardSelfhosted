#!/bin/sh
# media-init — idempotent, health-gated reconciliation of the media stack's
# inter-service wiring (annex §6, nixflix pattern: keys are pushed down via
# env, a oneshot does the rest over REST — no UI clicks).
#
# Runs in python:3.13-alpine (see compose.yaml for why not curl+jq). Reads the
# stack .env via env_file; mounts /mnt/slow/data at /data for the skeleton.
#
# Contract:
#   - Every mutation is logged as "media-init: CHANGE: ...". A second run must
#     log ZERO change lines — that is the idempotence property the media suite
#     asserts (protects Arcane redeploys).
#   - x265 GUARD (x265/H265 is ENFORCED — LONGRUN operating rule), BOTH
#     SIDES of the bias: in every quality profile, (a) any custom format
#     matching /x265|h.?265|hevc/i with a NEGATIVE score is zeroed — the
#     codified inversion of TRaSH's "x265 (HD) at -10000" golden rule; (b)
#     any CF matching /x264|h.?264|\bavc\b/i with a POSITIVE score is
#     INVERTED (score -> -score) — rewarding x264 defeats the policy exactly
#     as effectively as punishing x265; (c) where a profile carries both
#     kinds, the best x265 score must STRICTLY outrank the best x264 score
#     (a tie is demoted). Profilarr owns the profiles themselves; this guard
#     only stops x264-biased scoring from surviving.
#     Two deliberate consequences of (b): under the arrs' default
#     minFormatScore of 0, an inverted x264 CF makes x264-only releases
#     un-grabbable outright (not merely outranked) — that is the enforcement
#     rule, there is no x264 fallback tier. And if a synced Dictionarry
#     profile ever legitimately carries a positive x264 CF, every Profilarr
#     sync restores it and the next guard run re-inverts it — a permanent
#     sync-vs-guard churn in which "second run is a no-op" only holds
#     between syncs; the GUARD log lines are the tell.
#   - Profilarr: links the Dictionarry database (the ONLY allowed source);
#     hard-fails if a TRaSH-converted database (trash-pcd) is ever linked.
#     Linking needs egress (git clone), so failure to link is a loud WARN with
#     the documented one-time UI fallback, not a fatal — the offline suite
#     runs without egress.
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
        # The response body IS the diagnosis for Servarr validation failures
        # (a bare "HTTP 400" cost one whole suite cycle to identify).
        detail = e.read().decode(errors="replace")[:2000]
        log("HTTPERROR", f"{method} {url} -> {e.code}: {detail}")
        raise ApiError(e.code, detail) from None
    return json.loads(raw) if raw else None

def from_schema(schemas, impl, overrides, extra):
    # Servarr POST bodies are built from the matching /schema entry rather
    # than hand-rolled (nixflix pattern): hand-rolled bodies miss
    # implementation-contract fields and 400 on stricter versions.
    tmpl = next(s for s in schemas if s.get("implementation") == impl)
    for f in tmpl.get("fields", []):
        if f.get("name") in overrides:
            f["value"] = overrides[f["name"]]
    tmpl.update(extra)
    return tmpl

def wait_api(name, url, key, deadline=300):
    # Belt over the compose service_healthy braces: /ping healthy does not
    # guarantee the API key path is live yet.
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
    # Unset vars here usually mean the deploy raced the first .env decrypt
    # (finding #11's residual window) — fail loudly, Arcane redeploys retry.
    sys.exit(f"media-init: FATAL: unset env: {missing} (decrypt race? see finding #11)")

QBIT_USER = env["QBIT_WEBUI_USER"]
QBIT_PASS = env["QBIT_WEBUI_PASSWORD"]

# ---------------------------------------------------------------------------
# /data skeleton (hardlink-friendly single-filesystem layout, owned 1000:1000)
# ---------------------------------------------------------------------------
SKELETON = [
    "media/movies", "media/tv",
    "downloads/movies", "downloads/tv",
    # The audiobook category directory. Nothing *arr-shaped imports from it —
    # scan-downloads.sh promotes clean entries into the books stack's drop
    # directory (Option C, ServerNotes/designs/audiobook-acquisition.md) — but
    # it is created here with the rest so qBittorrent's category save path
    # exists before the first torrent lands.
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
# Naming formats are TRaSH's recommended schemes — codec-neutral, and the
# {MediaInfo VideoCodec}/{MediaInfo VideoDynamicRangeType} tokens are exactly
# what makes the x265 policy auditable on disk (annex §2).
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
        # Radarr/Sonarr run a live connection test on this POST and
        # forceSave=true does NOT override severity:error failures ("Unable
        # to connect" — proven by the media suite, contra the Servarr lore).
        # qBittorrent's WebUI answers on the shared netns even while the
        # tunnel is down, but only once the container is up — so retry
        # briefly (compose may still be starting it), then degrade to a loud
        # WARN: the next media-init run (any Arcane redeploy) reconciles it.
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
# Radarr and Sonarr create their own categories as a side effect of the
# download-client config above. Nothing creates this one — audiobooks have no
# *arr — so it is declared here, with an explicit save path, and that path is
# what scan-downloads.sh promotes clean entries OUT of. Doing it over the API
# rather than in qBittorrent.conf is deliberate: qbit-init only writes that
# file when it does not exist yet (qBittorrent owns it afterwards and rewrites
# it on shutdown), so a category added there would never reach an existing
# deployment.
#
# Best-effort like the download-client POST: qBittorrent shares gluetun's
# netns, so anything that keeps qbit from starting also makes this
# unreachable, and that must be a WARN the next run reconciles, never a
# failure that blocks the rest of the reconciliation.
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
        # qBittorrent treats a MISMATCHED Origin/Referer as cross-site and
        # 403s it; an absent one is fine, but sending the right one costs
        # nothing and survives a future tightening.
        headers["Referer"] = QBIT
    r = urllib.request.Request(
        QBIT + path, data=data, headers=headers,
        method="POST" if data is not None else "GET")
    with urllib.request.urlopen(r, timeout=30) as resp:
        return resp.status, resp.headers, resp.read().decode(errors="replace")


try:
    status, hdrs, body = qbit(None, "/api/v2/auth/login",
                              {"username": QBIT_USER, "password": QBIT_PASS})
    # SUCCESS IS NOT ONE SHAPE. The pinned qBittorrent 5.2.3 answers
    # 204 No Content with an EMPTY body (the media suite's own login subtest
    # pins exactly that); older builds answer 200 with the body "Ok.". A
    # wrong password is a 401, which urlopen raises. So: accept 204, accept
    # 200/"Ok.", reject anything else — and do NOT require a non-empty body,
    # which is what made the first cut of this log a permanent WARN with the
    # login actually succeeding.
    if not (status == 204 or (status == 200 and body.strip() == "Ok.")):
        raise RuntimeError(f"login refused: HTTP {status} {body.strip()[:80]!r}")
    # 🚨 THE COOKIE IS NOT CALLED "SID". qBittorrent 5.2.3 names the session
    # cookie QBT_SID_<WebUI port> — QBT_SID_8080 here — so a check for a
    # cookie named SID (which is what every qBittorrent API snippet on the
    # internet still says) finds nothing, sends no cookie, and gets a 403 on
    # the very next call. Take whatever name=value the server issued.
    sid = (hdrs.get("Set-Cookie") or "").split(";")[0].strip()
    if "=" not in sid:
        # No cookie at all: qBittorrent skips the session when auth is not
        # needed for this caller (WebUI\LocalHostAuth=false, local source).
        # Carry on without one; the next call 403s loudly if it was needed.
        sid = ""

    _, _, raw = qbit(sid, "/api/v2/torrents/categories")
    cats = json.loads(raw or "{}")
    cur = cats.get(AUDIOBOOK_CATEGORY)
    if cur is None:
        qbit(sid, "/api/v2/torrents/createCategory",
             {"category": AUDIOBOOK_CATEGORY, "savePath": AUDIOBOOK_SAVE_PATH})
        change(f"qbittorrent: created category {AUDIOBOOK_CATEGORY!r} "
               f"-> {AUDIOBOOK_SAVE_PATH}")
    # rstrip("/") on both sides: qBittorrent normalises the paths it stores
    # and a returned trailing separator would make every run "differ" — an
    # editCategory per run, i.e. a CHANGE line per run, which is the
    # idempotence contract the media suite asserts.
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
    # A name matching both regexes (e.g. "h264/h265") counts as x265, so the
    # zero-if-negative and invert-if-positive rules cannot fight over one item.
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
        # Strictness: where a profile carries BOTH kinds, x265 must outrank
        # x264 strictly — after the rules above x265 >= 0 >= x264, so the
        # only way to tie is both at 0; demote the tied x264 items to -1.
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
            # repository_url verified against v2.2.0 (its own validation
            # error names it, and a live POST with it succeeds). With egress
            # profilarr may also pre-link Dictionarry on first boot — the
            # "already linked" branch above catches that.
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
