#!/bin/sh
# kavita-config-init — renders /config/appsettings.json before kavita starts.
# Runs in python:3.13-alpine as a oneshot (annex §2.4/§3.1).
#
# Why a rendered file rather than environment variables: Kavita reads NO env
# vars at all. Program.CreateHostBuilder calls config.Sources.Clear() and adds
# only config/appsettings.json{,.<Environment>}, so this file is the entire
# configuration channel — including the OpenIdConnectSettings triple, which
# Seed.SetOidcSettingsFromDisk re-applies to the database on every boot. That
# re-apply is what makes sops-managed OIDC work: the file stays authoritative,
# and rotating the secret reaches the running server on the next stack up.
#
# Why the TokenKey is pre-seeded and the mount is read-WRITE (annex §0.5):
# Kavita's own EnsureJwtTokenKey, and every other writer of this file, is
# wrapped in a bare `catch { /* Swallow */ }`. On a read-only mount it does
# not crash and does not log — it just carries on signing every JWT with the
# placeholder key that ships in the public repository. A pre-seeded key plus a
# writable mount is the only combination that is both correct and observable.
#
# Semantics: MERGE, then rewrite only on change.
#   - Merge, not whole-file render (unlike immich-config-init): Kavita rewrites
#     this file itself, and it legitimately accumulates keys this template does
#     not own — Serilog, KnownProxies, and anything a future version adds via
#     JsonExtensionData. Clobbering those on every deploy would be a silent
#     config regression.
#   - Rewrite only on change, tmpfile+rename: the server never sees a
#     half-written file, and a second run logs zero CHANGE lines (which the
#     books suite asserts).
set -eu

exec python3 - <<'PY'
import json
import os
import sys
import tempfile

TEMPLATE = "/template/appsettings.json.template"
OUT = "/config/appsettings.json"

PLACEHOLDERS = {
    # required: an empty JWT signing key is the failure this whole script
    # exists to prevent.
    "__KAVITA_TOKEN_KEY__": ("KAVITA_TOKEN_KEY", True),
    # optional: empty is the shipping state. Kavita's `Enabled` is a computed
    # getter over (Authority, ClientId, Secret), so an empty secret cleanly
    # disables OIDC and leaves local accounts working — no half-configured
    # state (annex §3.1/§8.4). Filling it in, plus the Authentik side, is the
    # operator's step.
    "__KAVITA_OIDC_CLIENT_SECRET__": ("KAVITA_OIDC_CLIENT_SECRET", False),
}

values = {}
for placeholder, (var, required) in PLACEHOLDERS.items():
    value = os.environ.get(var, "")
    if required and not value:
        sys.exit(f"kavita-config-init: FATAL: {var} unset or empty in .env "
                 f"(decrypt race? finding #11)")
    values[placeholder] = value


def substitute(node):
    """Replace placeholders in the PARSED structure, not in the file text.

    Substituting after the parse means a value containing a quote or a
    backslash can never corrupt the document — the json writer escapes it.
    That is the hazard immich-config-init has to guard against explicitly
    because it does a text pass with awk.
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

# With no client secret, the Authority is blanked too — Kavita has TWO
# `Enabled` computations and they disagree:
#
#   Kavita.Common/Configuration.cs   Authority && ClientId && Secret  (disk;
#                                    decides whether OIDC is REGISTERED)
#   DTOs/Settings/OidcConfigDto.cs   Authority alone                  (DB;
#                                    decides whether the login page and
#                                    AccountController treat OIDC as live)
#
# Seed.SetOidcSettingsFromDisk copies the Authority into the DB row on every
# boot, so an Authority-with-no-Secret leaves the DB-side flag TRUE while
# nothing is registered. That is inert today, but it is exactly the state in
# which `disablePasswordAuthentication` would lock every account out of a
# login that cannot be replaced — an API key would be the only way back in.
# Blanking the Authority makes both computations agree, so the OFF state is
# unambiguous rather than merely harmless.
oidc = desired.get("OpenIdConnectSettings")
if isinstance(oidc, dict) and not oidc.get("Secret"):
    oidc["Authority"] = ""
    print("kavita-config-init: no OIDC client secret - OIDC left disabled")


def merge(current, desired):
    """Recursive per-key merge; returns (merged, changed)."""
    merged = dict(current)
    changed = False
    for key, value in desired.items():
        # `is None` counts as absent rather than as a differing scalar:
        # otherwise a serialized `"OpenIdConnectSettings": null` would take
        # the replace branch and report a CHANGE on every single run.
        if isinstance(value, dict) and merged.get(key) is None:
            merged[key] = {}
        if isinstance(value, dict) and isinstance(merged.get(key), dict):
            sub, sub_changed = merge(merged[key], value)
            if sub_changed:
                merged[key] = sub
                changed = True
        elif merged.get(key) != value:
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
        # A corrupt appsettings.json is not something to preserve: Kavita would
        # fail to start on it. Say so loudly and replace it.
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
