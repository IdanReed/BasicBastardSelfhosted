#!/bin/sh
# bazarr-init — Bazarr's subtitle policy, reconciled over its API on every
# run. Runs in python:3.13-alpine as a oneshot once bazarr is healthy;
# bazarr-config-init has already pinned the API key it signs in with.
#
# Declared state:
#   - one language profile, "English": English only, the "normal or
#     hearing-impaired" type, not forced. Forced subtitles carry only the
#     foreign-language lines, so they are not the one full track wanted here.
#     Bazarr has no "normal only" type, so the Sub-Zero `remove_HI` mod is on:
#     a hearing-impaired result is stripped of its HI text and saved as plain
#     English. A profile made by hand is removed (the API saves the list
#     whole).
#   - that profile is the default for series AND movies, and every item that
#     has no profile — everything Bazarr synced before this ran — gets it.
#   - providers: the ones Bazarr 1.6.0 ships that need no account and serve
#     English — Gestdown (an Addic7ed proxy) and TVSubtitles for episodes,
#     YIFY Subtitles for movies — plus OpenSubtitles.com once
#     OPENSUBTITLES_USERNAME/PASSWORD are real (a `changeme` placeholder keeps
#     it off and its credentials empty, rather than failing logins on every
#     search).
#   - one subtitle per item: Bazarr saves a single file per profile language
#     (a second candidate for a saved language is skipped), and upgrades
#     replace that file. single_language stays OFF: it would drop the `.en`
#     from the filename, and Jellyfin then cannot tell the track is English.
#
# Every mutation logs "bazarr-init: CHANGE: ..."; a second run must log ZERO.
set -eu

exec python3 -u - <<'PY'
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

BASE = os.environ.get("BAZARR_URL", "http://bazarr:6767")
CHANGES = 0

PROFILE_NAME = "English"
FREE_PROVIDERS = ["gestdown", "tvsubtitles", "yifysubtitles"]
OPENSUBTITLES = "opensubtitlescom"


def log(msg):
    print(f"bazarr-init: {msg}", flush=True)


def change(msg):
    global CHANGES
    CHANGES += 1
    print(f"bazarr-init: CHANGE: {msg}", flush=True)


def call(path, method="GET", form=None, timeout=120):
    # Bazarr's write endpoints take form fields, repeated for a list.
    data = urllib.parse.urlencode(form, doseq=True).encode() if form is not None else None
    headers = {"X-API-KEY": API_KEY}
    if data is not None:
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    req = urllib.request.Request(BASE + path, data=data, headers=headers,
                                 method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode(errors="replace")
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")[:500]
        sys.exit(f"bazarr-init: FATAL: {method} {path} HTTP {e.code}: {body}")
    return json.loads(raw) if raw.strip() else None


API_KEY = os.environ.get("BAZARR_API_KEY") or ""
if not API_KEY:
    sys.exit("bazarr-init: FATAL: BAZARR_API_KEY unset or empty (decrypt race?)")


def placeholder(v):
    return not v or v.startswith("changeme")


os_user = os.environ.get("OPENSUBTITLES_USERNAME") or ""
os_pass = os.environ.get("OPENSUBTITLES_PASSWORD") or ""
os_on = not (placeholder(os_user) or placeholder(os_pass))
if not os_on:
    log("OpenSubtitles.com stays off: OPENSUBTITLES_USERNAME/PASSWORD are "
        "still placeholders (fill them with sopsedit)")

# 1. The enabled languages (what profiles may use): English alone.
langs = call("/api/system/languages") or []
enabled = sorted(l["code2"] for l in langs if l.get("enabled"))
if enabled != ["en"]:
    call("/api/system/settings", "POST", {"languages-enabled": ["en"]})
    change(f"enabled languages {enabled} -> ['en']")
else:
    log("English is the only enabled language - no change")

# 2. The profile. Stored values are Python-boolean strings.
profiles = call("/api/system/languages/profiles") or []
mine = next((p for p in profiles if p.get("name") == PROFILE_NAME), None)
pid = mine["profileId"] if mine else max([p["profileId"] for p in profiles] + [0]) + 1
want = {
    "profileId": pid,
    "name": PROFILE_NAME,
    "cutoff": None,
    "items": [{"id": 1, "language": "en", "hi": "False", "forced": "False",
               "audio_exclude": "False", "audio_only_include": "False"}],
    "mustContain": [],
    "mustNotContain": [],
    "originalFormat": None,
    "tag": None,
}
if profiles != [want]:
    call("/api/system/settings", "POST", {"languages-profiles": json.dumps([want])})
    gone = [p.get("name") for p in profiles if p.get("profileId") != pid]
    change(f"language profile {PROFILE_NAME!r} (id {pid}) declared"
           + (f"; removed {gone}" if gone else ""))
else:
    log(f"language profile {PROFILE_NAME!r} already declared - no change")

# 3. Defaults, providers, the HI mod. subzero_mods is a list Bazarr APPENDS
# to, so remove_HI is only sent when it is missing.
settings = call("/api/system/settings") or {}
general = settings.get("general") or {}
oscom = settings.get("opensubtitlescom") or {}
providers = FREE_PROVIDERS + ([OPENSUBTITLES] if os_on else [])
form, drift = {}, []


def declare(key, value, current):
    """Queue one settings field when it differs. Bazarr reads `true`/`false`
    as booleans, and an empty list as one empty value."""
    if current == value:
        return
    if isinstance(value, list):
        form[key] = value or [""]
    elif isinstance(value, bool):
        form[key] = ["true" if value else "false"]
    else:
        form[key] = [str(value)]
    drift.append(key.rsplit("-", 1)[-1])


declare("settings-general-serie_default_enabled", True, general.get("serie_default_enabled"))
declare("settings-general-serie_default_profile", str(pid), str(general.get("serie_default_profile")))
declare("settings-general-movie_default_enabled", True, general.get("movie_default_enabled"))
declare("settings-general-movie_default_profile", str(pid), str(general.get("movie_default_profile")))
declare("settings-general-single_language", False, general.get("single_language"))
declare("settings-general-enabled_providers", sorted(providers),
        sorted(general.get("enabled_providers") or []))
declare("settings-opensubtitlescom-username", os_user if os_on else "", oscom.get("username") or "")
declare("settings-opensubtitlescom-password", os_pass if os_on else "", oscom.get("password") or "")
if "remove_HI" not in (general.get("subzero_mods") or []):
    form["subzero-remove_HI"] = ["true"]
    drift.append("subzero remove_HI")
if form:
    call("/api/system/settings", "POST", form)
    # Never echo a credential: name the keys, not the values.
    change(f"settings written ({', '.join(drift)}); providers {sorted(providers)}")
else:
    log(f"defaults, providers {sorted(providers)} and the HI mod already set - no change")

# 4. Items synced before the defaults existed carry no profile.
for kind, path, id_field, form_field in (
        ("series", "/api/series", "sonarrSeriesId", "seriesid"),
        ("movies", "/api/movies", "radarrId", "radarrid")):
    items = (call(path) or {}).get("data") or []
    bare = [i[id_field] for i in items if i.get("profileId") is None]
    if bare:
        call(path, "POST", {form_field: bare, "profileid": [str(pid)] * len(bare)})
        change(f"{len(bare)} {kind} without a profile -> {PROFILE_NAME!r}")
    else:
        log(f"all {len(items)} {kind} have a profile - no change")

log(f"done ({CHANGES} change(s))")
PY
