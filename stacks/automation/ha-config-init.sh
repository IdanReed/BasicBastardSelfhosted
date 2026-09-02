#!/bin/sh
# ha-config-init — pre-seeds /config/.storage/http before Home Assistant
# starts. Runs in python:3.13-alpine as a oneshot (annex §3.1).
#
# WHY: HA 2026.8.0 retired the `http:` YAML block — it is migrated exactly
# ONCE into storage-backed config, staged *pending*, and unless an admin
# promotes it in the UI within AUTO_REVERT_DELAY (5 minutes) HA restores the
# previous stable config; the failed pending one "is kept for inspection but
# never applied again". Headless, reverse-proxy trust works for five minutes
# and then permanently does not, healthcheck green throughout. It matters
# because Caddy always sends X-Forwarded-For, and HA 400s EVERY request
# carrying that header without use_x_forwarded_for + trusted_proxies.
#
# So this writes a `stable` config directly, with `pending: null` and
# `yaml_migration_done: true` — resolves to ActiveConfigType.STABLE, no
# revert ever scheduled, and HA logs "Using stable HTTP config", which is
# exactly what the suite asserts.
#
# ⚠ The store is NOT re-validated on load. HTTP_STORAGE_SCHEMA runs only on
# migration and on the websocket configure command, so a malformed file here
# does not raise — it silently 400s every proxied request. Hence the suite
# drives a real proxied request rather than trusting this file's shape.
#
# Semantics: MERGE, then rewrite only on change — the same contract as
# kavita-config-init. HA owns everything else under .storage/, and a future
# version may add keys to this file that this template does not know about.
set -eu

exec python3 - <<'PY'
import json
import os
import sys
import tempfile

TEMPLATE = "/template/http.json.template"
STORAGE = "/config/.storage"
OUT = os.path.join(STORAGE, "http")

# The proxy Home Assistant must trust. NOT 127.0.0.1: a loopback publish does
# not preserve the source address — docker-proxy terminates the connection and
# re-dials from the bridge gateway, so HA sees the gateway. The compose file
# pins the subnet precisely so this value is stable across recreates.
PROXY = os.environ.get("HA_TRUSTED_PROXY", "10.89.250.1/32")
if "/" not in PROXY:
    # ip_network() rejects a host address with a prefix, and a bare address is
    # ambiguous. Fail loudly rather than write something that silently 400s.
    sys.exit(f"ha-config-init: FATAL: HA_TRUSTED_PROXY={PROXY!r} is not a "
             f"network in CIDR form (e.g. 10.89.250.1/32)")

with open(TEMPLATE) as fh:
    desired = json.load(fh)

desired["data"]["stable"]["trusted_proxies"] = [PROXY]


# Absence and a null VALUE are different things and `.get()` cannot tell
# them apart — that once silently dropped `"pending": null`, and HA does raw
# key access on `pending`, so the rendered file would KeyError on load.
MISSING = object()


def merge(current, desired):
    """Recursive per-key merge; returns (merged, changed)."""
    merged = dict(current)
    changed = False
    for key, value in desired.items():
        have = merged.get(key, MISSING)
        if isinstance(value, dict) and (have is MISSING or have is None):
            merged[key] = {}
            have = merged[key]
        if isinstance(value, dict) and isinstance(have, dict):
            sub, sub_changed = merge(have, value)
            if sub_changed:
                merged[key] = sub
                changed = True
        elif have is MISSING or have != value:
            merged[key] = value
            changed = True
    return merged, changed


current = {}
if os.path.exists(OUT):
    try:
        with open(OUT) as fh:
            current = json.load(fh)
        if not isinstance(current, dict):
            raise ValueError("top level is not an object")
    except (ValueError, OSError) as exc:
        print(f"ha-config-init: existing .storage/http unreadable ({exc}) — "
              f"replacing")
        current = {}

merged, changed = merge(current, desired)

# One key this must NOT merge-preserve: a `pending` config left over from a
# previous boot is exactly the state that gets auto-reverted, so it is forced
# back to null rather than carried forward.
if merged.get("data", {}).get("pending") is not None:
    merged["data"]["pending"] = None
    changed = True

if not changed and current:
    print("ha-config-init: .storage/http up to date - no change")
    sys.exit(0)

os.makedirs(STORAGE, exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=STORAGE, prefix=".http.")
try:
    with os.fdopen(fd, "w") as fh:
        json.dump(merged, fh, indent=2)
        fh.write("\n")
    # HA writes its own store files 0600 (private=True); match it.
    os.chmod(tmp, 0o600)
    os.replace(tmp, OUT)
except BaseException:
    os.unlink(tmp)
    raise

print(f"ha-config-init: CHANGE: seeded .storage/http (trusted proxy {PROXY})")
PY
