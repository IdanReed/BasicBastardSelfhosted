#!/bin/sh
# ha-config-init — pre-seeds /config/.storage/http before Home Assistant
# starts.
#
# HA 2026.8.0 retired the `http:` YAML block: it is migrated once, staged
# *pending*, and reverted after 5 minutes unless an admin promotes it in the
# UI — so headless, reverse-proxy trust works for five minutes and then
# permanently does not, healthcheck green throughout. That matters because
# Caddy always sends X-Forwarded-For and HA 400s every request carrying it
# without use_x_forwarded_for + trusted_proxies.
#
# So this writes a `stable` config directly, with `pending: null` and
# `yaml_migration_done: true`, and no revert is ever scheduled.
#
# ⚠ The store is NOT re-validated on load, so a malformed file here does not
# raise — it silently 400s every proxied request. The suite drives a real
# proxied request rather than trusting this file's shape.
#
# MERGE, then rewrite only on change: HA owns everything else under .storage/.
set -eu

exec python3 - <<'PY'
import json
import os
import sys
import tempfile

TEMPLATE = "/template/http.json.template"
STORAGE = "/config/.storage"
OUT = os.path.join(STORAGE, "http")

# NOT 127.0.0.1: docker-proxy terminates the connection and re-dials from the
# bridge gateway, so that is what HA sees. The compose file pins the subnet
# precisely so this value is stable across recreates.
PROXY = os.environ.get("HA_TRUSTED_PROXY", "10.89.250.1/32")
if "/" not in PROXY:
    # ip_network() rejects a host address with a prefix, and a bare address is
    # ambiguous. Fail loudly rather than write something that silently 400s.
    sys.exit(f"ha-config-init: FATAL: HA_TRUSTED_PROXY={PROXY!r} is not a "
             f"network in CIDR form (e.g. 10.89.250.1/32)")

with open(TEMPLATE) as fh:
    desired = json.load(fh)

desired["data"]["stable"]["trusted_proxies"] = [PROXY]


# Absence and a null VALUE differ and `.get()` cannot tell them apart — that
# once dropped `"pending": null`, which HA reads by raw key access.
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

# The one key this must NOT merge-preserve: a leftover `pending` config is
# exactly the state that gets auto-reverted.
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
