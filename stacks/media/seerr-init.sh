#!/bin/sh
# seerr-init — /config ownership plus a seeded settings.json, BEFORE seerr
# starts. Runs in python:3.13-alpine as a oneshot. The three calls that need a
# RUNNING seerr live in seerr-bootstrap.sh; the two are separate services
# because they sit on opposite sides of seerr's own start.
#
# 🚨 THE SEED FILE MUST CONTAIN A `main` OBJECT. settings/migrator.ts runs
# every migration on the raw parsed JSON before the defaults merge and
# process.exit()s on any throw; 0004 dereferences main.discoverRegion and 0005
# main.csrfProtection unconditionally. A settings.json without `main` is a boot
# loop, not a warning.
#
# 🚨 main.mediaServerType MUST BE PRESENT, AND MUST BE 4 (NOT_CONFIGURED).
# Present: overseerrMerge.ts's checkOverseerrMerge loads settings RAW —
# `new Settings().load(undefined, true)`, which skips the defaults merge — and
# treats a falsy mediaServerType as "not yet migrated from Overseerr". It then
# INSERTs into a `migrations` table that does not exist on a virgin db.sqlite3
# and process.exit(1)s: a crash loop, measured, not theorised.
# 4 rather than 2: migration 0002 fires when it is 2/3 while jellyfin.apiKey is
# empty, calling Jellyfin to mint a token and exiting on failure. The auth call
# in seerr-bootstrap sets the real value.
#
# 🚨 jellyfin.ip MUST BE "": auth.ts refuses with a 500 "Jellyfin hostname
# already configured" if it is non-empty and a hostname is sent.
#
# The pre-populated `migrations` list is not cosmetic: 0007 otherwise connects
# to each arr and RENAMES tags on it, on every boot, for any entry with
# tagRequests true.
#
# Every mutation logs "seerr-init: CHANGE: ..."; a second run must log ZERO.
set -eu

exec python3 -u - <<'PY'
import json
import os
import sys

CONFIG = "/config"
SETTINGS = os.path.join(CONFIG, "settings.json")
TEMPLATE = "/template/settings.json"

required = ("RADARR__AUTH__APIKEY", "SONARR__AUTH__APIKEY")
missing = [k for k in required if not os.environ.get(k)]
if missing:
    sys.exit(f"seerr-init: FATAL: unset or empty in .env: "
             f"{', '.join(missing)} (decrypt race?)")

# Seerr runs as uid 1000 and cannot chown its own config dir; docker creates
# bind-mount sources root-owned, so without this it crash-loops on EACCES
# mkdir /app/config/logs on ANY first deploy.
for root, dirs, files in os.walk(CONFIG):
    for name in dirs + files:
        os.chown(os.path.join(root, name), 1000, 1000)
os.chown(CONFIG, 1000, 1000)
print("seerr-init: /config owned 1000:1000", flush=True)

# Seed-if-absent, NOT merge: Seerr rewrites this file whole on every save, so
# a merge on each deploy would revert anything changed in the UI.
if os.path.exists(SETTINGS):
    print("seerr-init: settings.json exists - seerr owns it, not touching",
          flush=True)
    sys.exit(0)

with open(TEMPLATE) as fh:
    seed = json.load(fh)

# The arr connections carry API keys, so they are injected from .env rather
# than committed. `id` starts at 0; POST /settings/radarr assigns last.id + 1
# for anything added later.
seed["radarr"] = [{
    "id": 0, "name": "Radarr", "hostname": "radarr", "port": 7878,
    "apiKey": os.environ["RADARR__AUTH__APIKEY"], "useSsl": False,
    "baseUrl": "", "activeProfileId": 1, "activeProfileName": "Any",
    "activeDirectory": "/data/media/movies", "tags": [], "is4k": False,
    "isDefault": True, "syncEnabled": True, "preventSearch": False,
    # tagRequests MUST stay false: migration 0007 connects to the arr and
    # RENAMES tags on it for any entry that has it on.
    "tagRequests": False, "overrideRule": [],
    "minimumAvailability": "released",
}]
seed["sonarr"] = [{
    "id": 0, "name": "Sonarr", "hostname": "sonarr", "port": 8989,
    "apiKey": os.environ["SONARR__AUTH__APIKEY"], "useSsl": False,
    "baseUrl": "", "activeProfileId": 1, "activeProfileName": "Any",
    "activeDirectory": "/data/media/tv", "tags": [], "is4k": False,
    "isDefault": True, "syncEnabled": True, "preventSearch": False,
    "tagRequests": False, "overrideRule": [], "seriesType": "standard",
    "animeSeriesType": "anime", "enableSeasonFolders": True,
    "monitorNewItems": "all",
}]

tmp = SETTINGS + ".seed.tmp"
with open(tmp, "w") as fh:
    json.dump(seed, fh, indent=1)
os.chmod(tmp, 0o600)
os.chown(tmp, 1000, 1000)
os.replace(tmp, SETTINGS)
print("seerr-init: CHANGE: seeded settings.json (main + radarr + sonarr)",
      flush=True)
PY
