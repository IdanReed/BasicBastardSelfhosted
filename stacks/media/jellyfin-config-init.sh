#!/bin/sh
# jellyfin-config-init — what has to be on disk BEFORE jellyfin starts. Runs in
# python:3.13-alpine as a oneshot; jellyfin depends on it completing.
#
#   1. config/encoding.xml, seeded once (VA-API on). There is no env var for
#      any EncodingOptions field and the API needs an admin token that does not
#      exist yet, so a file is the only channel. Seed-if-absent, NOT merge —
#      jellyfin rewrites it whenever an admin saves the Transcoding page.
#   2. The LDAP plugin (jellyfin-ldap.json: version, URL, sha256), because
#      plugins load only at startup. jellyfin-init configures it afterwards.
#   3. No SSO-Auth plugin: Jellyfin is not on OIDC (TV and mobile clients
#      cannot follow the redirect). An install from an earlier deploy is
#      removed together with its stored config, which holds a retired client
#      secret.
#
# ⚠ Deliberately does NOT seed config/system.xml; see jellyfin-init.sh.
#
# The plugin download is the one step that needs egress, so its failure is a
# WARN, never fatal: Jellyfin still starts (local accounts work), jellyfin-init
# warns that LDAP logins are off, and the next deploy retries. A verified zip
# is kept in /config/plugin-cache, so a reinstall never downloads twice.
#
# Every mutation logs "jellyfin-config-init: CHANGE: ..."; a second run must
# log ZERO.
set -eu

exec python3 -u - <<'PY'
import glob
import hashlib
import json
import os
import shutil
import sys
import tempfile
import urllib.request
import zipfile

CONFIG = "/config"
PLUGINS = os.path.join(CONFIG, "plugins")
# Outside plugins/: jellyfin treats every directory there as a plugin.
CACHE = os.path.join(CONFIG, "plugin-cache")


def log(msg):
    print(f"jellyfin-config-init: {msg}", flush=True)


def change(msg):
    print(f"jellyfin-config-init: CHANGE: {msg}", flush=True)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


# 1. encoding.xml. Tmpfile+rename: the existence guard is touch-once, so a
# crash mid-write would leave a partial XML that jellyfin logs and then
# ignores in favour of defaults.
dest = os.path.join(CONFIG, "config", "encoding.xml")
if os.path.exists(dest):
    log(f"{dest} exists - jellyfin owns it, not touching")
else:
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    shutil.copyfile("/template/encoding.xml", dest + ".tmp")
    os.replace(dest + ".tmp", dest)
    change(f"seeded {dest} (vaapi)")

# 2. The LDAP plugin.
with open("/template/jellyfin-ldap.json") as fh:
    spec = json.load(fh)["plugin"]
guid = spec["guid"].replace("-", "").lower()
want_dir = os.path.join(PLUGINS, f"LDAP-Auth_{spec['version']}")
# Records which zip the directory was unpacked from; jellyfin rewrites
# meta.json itself, so that cannot be the marker.
marker = os.path.join(want_dir, ".zip-sha256")


def plugin_guid(directory):
    try:
        with open(os.path.join(directory, "meta.json")) as fh:
            return str(json.load(fh).get("guid", "")).replace("-", "").lower()
    except (OSError, ValueError):
        return ""


def fetch_zip():
    """The verified zip in the cache, downloading it if needed; None on failure."""
    os.makedirs(CACHE, exist_ok=True)
    cached = os.path.join(CACHE, os.path.basename(spec["url"]))
    if os.path.exists(cached) and sha256(cached) == spec["sha256"]:
        return cached
    tmp = cached + ".part"
    try:
        with urllib.request.urlopen(spec["url"], timeout=120) as resp, \
                open(tmp, "wb") as out:
            shutil.copyfileobj(resp, out)
    except Exception as e:  # noqa: BLE001 — any failure means "no egress now"
        log(f"WARN: could not download {spec['url']} ({e}) - LDAP logins stay "
            f"off until a deploy can fetch it")
        return None
    got = sha256(tmp)
    if got != spec["sha256"]:
        os.unlink(tmp)
        log(f"WARN: {spec['url']} has sha256 {got}, expected {spec['sha256']} "
            f"- refusing to install it")
        return None
    os.replace(tmp, cached)
    change(f"downloaded {os.path.basename(cached)} (sha256 verified)")
    return cached


installed = False
if os.path.exists(marker) and open(marker).read().strip() == spec["sha256"]:
    log(f"LDAP plugin {spec['version']} already installed - no change")
    installed = True
else:
    zpath = fetch_zip()
    if zpath:
        os.makedirs(PLUGINS, exist_ok=True)
        # Unpacked beside the cache and moved in whole: a half-written
        # directory under plugins/ would be loaded as a broken plugin.
        stage = tempfile.mkdtemp(prefix="ldap-auth.", dir=CACHE)
        os.chmod(stage, 0o755)  # mkdtemp's 0700 would follow it into plugins/
        with zipfile.ZipFile(zpath) as z:
            z.extractall(stage)
        meta_path = os.path.join(stage, "meta.json")
        with open(meta_path) as fh:
            meta = json.load(fh)
        # The pin is the version: jellyfin's plugin-update task would
        # otherwise replace it with whatever the catalogue offers next.
        meta["autoUpdate"] = False
        with open(meta_path, "w") as fh:
            json.dump(meta, fh, indent=2)
        with open(os.path.join(stage, ".zip-sha256"), "w") as fh:
            fh.write(spec["sha256"] + "\n")
        if os.path.exists(want_dir):
            shutil.rmtree(want_dir)
        os.replace(stage, want_dir)
        change(f"installed the LDAP plugin {spec['version']} into {want_dir}")
        installed = True

# Any other copy of the same plugin (another version, a catalogue install)
# would be loaded beside the pin.
if installed:
    for d in sorted(glob.glob(os.path.join(PLUGINS, "*"))):
        if d != want_dir and os.path.isdir(d) and plugin_guid(d) == guid:
            shutil.rmtree(d)
            change(f"removed {d} (the LDAP plugin is pinned to {spec['version']})")

# 3. No SSO plugin.
found = glob.glob(os.path.join(PLUGINS, "SSO-Auth_*"))
sso_xml = os.path.join(PLUGINS, "configurations", "SSO-Auth.xml")
if found or os.path.exists(sso_xml):
    for d in found:
        shutil.rmtree(d)
    if os.path.exists(sso_xml):
        os.unlink(sso_xml)
    change("removed the SSO-Auth plugin and its config")
else:
    log("no SSO-Auth plugin - no change")
PY
