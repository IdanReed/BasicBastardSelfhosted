#!/bin/sh
# kavita-config-init — renders /config/appsettings.json before kavita starts.
#
# Kavita reads NO env vars, so this file is its entire configuration channel,
# including the OpenIdConnectSettings triple that Seed.SetOidcSettingsFromDisk
# re-applies to the database on every boot — which is what makes sops-managed
# OIDC work at all.
#
# The TokenKey is pre-seeded and the mount is read-WRITE because every writer
# of this file is wrapped in a bare `catch {}`: a read-only mount does not
# crash and does not log, it just signs every JWT with the placeholder key
# that ships in the public repository.
#
# MERGE, not whole-file render: Kavita rewrites the file itself and it
# accumulates keys this template does not own. Rewrite only on change, via
# tmpfile+rename, so a second run logs zero CHANGE lines.
set -eu

exec python3 - <<'PY'
import json
import os
import sys
import tempfile

TEMPLATE = "/template/appsettings.json.template"
OUT = "/config/appsettings.json"

PLACEHOLDERS = {
    # An empty JWT signing key is the failure this script exists to prevent.
    "__KAVITA_TOKEN_KEY__": ("KAVITA_TOKEN_KEY", True),
    # Optional: empty is the shipping state, and cleanly disables OIDC while
    # leaving local accounts working.
    "__KAVITA_OIDC_CLIENT_SECRET__": ("KAVITA_OIDC_CLIENT_SECRET", False),
}

values = {}
for placeholder, (var, required) in PLACEHOLDERS.items():
    value = os.environ.get(var, "")
    if required and not value:
        sys.exit(f"kavita-config-init: FATAL: {var} unset or empty in .env "
                 f"(decrypt race?)")
    values[placeholder] = value


def substitute(node):
    """Replace placeholders in the PARSED structure, not in the file text,
    so a value containing a quote or backslash cannot corrupt the document.
    """
    if isinstance(node, dict):
        return {k: substitute(v) for k, v in node.items()}
    if isinstance(node, list):
        return [substitute(v) for v in node]
    if isinstance(node, str) and node in values:
        return values[node]
    return node


with open(TEMPLATE) as fh:
    desired = substitute(json.load(fh))

# With no client secret the Authority is blanked too, because Kavita computes
# "OIDC enabled" two ways that disagree: Authority+ClientId+Secret on disk
# (whether it is REGISTERED) and Authority alone in the DB (whether the login
# page treats it as live). An Authority with no Secret leaves the DB flag true
# with nothing registered — the exact state in which
# `disablePasswordAuthentication` would lock every account out.
oidc = desired.get("OpenIdConnectSettings")
if isinstance(oidc, dict) and not oidc.get("Secret"):
    oidc["Authority"] = ""
    print("kavita-config-init: no OIDC client secret - OIDC left disabled")


# Absence and a null VALUE differ and `.get()` cannot tell them apart. Latent
# here, but the identical merge in ha-config-init silently dropped a
# `"pending": null` key — same code, same fix, in both copies.
MISSING = object()


def merge(current, desired):
    """Recursive per-key merge; returns (merged, changed)."""
    merged = dict(current)
    changed = False
    for key, value in desired.items():
        have = merged.get(key, MISSING)
        # A serialized `"…": null` counts as absent rather than a differing
        # scalar, which would report a CHANGE on every run.
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
        # Not worth preserving: Kavita would fail to start on it.
        print(f"kavita-config-init: existing appsettings.json unreadable "
              f"({exc}) — replacing")
        current = {}

merged, changed = merge(current, desired)

if not changed and current:
    print("kavita-config-init: appsettings.json up to date - no change")
    sys.exit(0)

os.makedirs(os.path.dirname(OUT), exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(OUT), prefix=".appsettings.")
try:
    with os.fdopen(fd, "w") as fh:
        json.dump(merged, fh, indent=2)
        fh.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, OUT)
except BaseException:
    os.unlink(tmp)
    raise

print("kavita-config-init: CHANGE: rendered appsettings.json")
PY
