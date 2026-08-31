#!/bin/sh
# automation-init — headless Home Assistant onboarding (annex §3.1). Runs in
# python:3.13-alpine as a oneshot once HA is healthy.
#
# HA's onboarding is normally a browser wizard, but it is four plain REST
# calls and the wizard uses the same ones. Contract (media-init pattern):
#   - Every mutation logs "automation-init: CHANGE: ...". A second run — every
#     Arcane redeploy reruns this container — must log ZERO change lines.
#   - Unset credentials are a HARD error (decrypt race, finding #11).
#
# Idempotence here has TWO regimes and both mean "already done":
#   - 403 "<step> step already done"  — same process, step already run.
#   - 404                              — onboarding is complete AND HA has
#     restarted since; the component returns before registering any view, so
#     the whole /api/onboarding* namespace stops existing.
# Treat {200, 403, 404} as success on every step.
set -eu

exec python3 - <<'PY'
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

BASE = os.environ.get("HA_URL", "http://homeassistant:8123")

# Must be an http(s) URL (HA parses it as an IndieAuth client id) and must be
# byte-identical across calls — the authorization-code store keys on
# (client_id, code). It is never fetched on this path.
CLIENT_ID = BASE.rstrip("/") + "/"

changes = 0


def log(msg):
    print(f"automation-init: {msg}", flush=True)


def change(msg):
    global changes
    changes += 1
    print(f"automation-init: CHANGE: {msg}", flush=True)


def call(path, method="GET", body=None, form=None, token=None, timeout=60):
    """Returns (status, parsed-json-or-text). Raises HTTPError to the caller."""
    headers = {}
    data = None
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if form is not None:
        # /auth/token is FORM-encoded, not JSON — it reads request.post(), and
        # a JSON body comes back as 400 unsupported_grant_type.
        data = urllib.parse.urlencode(form).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    elif body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(BASE + path, data=data, headers=headers,
                                 method=method)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read().decode(errors="replace")
        try:
            return resp.status, json.loads(raw) if raw else None
        except ValueError:
            return resp.status, raw


def detail(exc):
    try:
        return exc.read().decode(errors="replace")[:500]
    except Exception:
        return ""


required = ("HA_ADMIN_NAME", "HA_ADMIN_USER", "HA_ADMIN_PASSWORD",
            "MQTT_HA_PASSWORD")
missing = [k for k in required if not os.environ.get(k)]
if missing:
    sys.exit(f"automation-init: FATAL: unset or empty in .env: "
             f"{', '.join(missing)} (decrypt race? finding #11)")


def seed_mqtt(token):
    """Create the MQTT config entry through the config-flow REST API.

    This is here because `mqtt:` in configuration.yaml does NOT work: its YAML
    schema accepts only platform names, so broker/port/username/password come
    back as "extra keys not allowed", HA starts anyway, and the integration
    silently never sets up. The broker connection is a config ENTRY, and this
    is the same flow the UI drives.

    Idempotent by construction: mqtt declares single_config_entry, so a second
    run aborts with `single_instance_allowed`, which is a no-change.
    """
    password = os.environ.get("MQTT_HA_PASSWORD", "")
    if not password:
        sys.exit("automation-init: FATAL: MQTT_HA_PASSWORD unset or empty in "
                 ".env (decrypt race? finding #11)")
    try:
        _, flow = call("/api/config/config_entries/flow", "POST",
                       {"handler": "mqtt", "show_advanced_options": False},
                       token=token)
    except urllib.error.HTTPError as e:
        sys.exit(f"automation-init: FATAL: starting the mqtt config flow "
                 f"returned HTTP {e.code}: {detail(e)}")

    reason = (flow or {}).get("reason")
    if (flow or {}).get("type") == "abort":
        if reason == "single_instance_allowed":
            log("mqtt config entry already exists - no change")
            return
        sys.exit(f"automation-init: FATAL: mqtt config flow aborted: {reason}")

    flow_id = (flow or {}).get("flow_id")
    if not flow_id:
        sys.exit(f"automation-init: FATAL: mqtt config flow returned no "
                 f"flow_id: {flow!r}")

    # The broker step. Reached by service name on the compose network — the
    # same address frigate uses, and the reason mosquitto needs no host
    # publish for the stack's own event chain to work.
    #
    # `other_settings` is REQUIRED and is a voluptuous *section*, so the
    # browser's collapsed "advanced" panel is not optional over the API — its
    # absence is a 400 `{"other_settings": "required key not provided"}`. Two
    # of its members are required in turn (`set_client_cert`, `set_ca_cert`),
    # and `transport` carries a default that only applies if the key is
    # present. Plain TCP, no client certificate, no CA verification: the
    # broker is on the compose network and speaks plaintext MQTT.
    try:
        _, res = call(f"/api/config/config_entries/flow/{flow_id}", "POST", {
            "broker": os.environ.get("MQTT_BROKER", "mosquitto"),
            "port": int(os.environ.get("MQTT_PORT", "1883")),
            "protocol": "5",
            "username": "homeassistant",
            "password": password,
            "other_settings": {
                "set_client_cert": False,
                "set_ca_cert": "off",
                "transport": "tcp",
            },
        }, token=token)
    except urllib.error.HTTPError as e:
        sys.exit(f"automation-init: FATAL: mqtt broker step HTTP {e.code}: "
                 f"{detail(e)}")

    if (res or {}).get("type") == "create_entry":
        change("home assistant mqtt config entry created")
    else:
        # A form back means validation failed — almost always "cannot_connect"
        # (broker down or credentials wrong). Loud, because a silently
        # unconnected broker is the exact failure this function exists to
        # prevent.
        sys.exit(f"automation-init: FATAL: mqtt broker step did not create an "
                 f"entry: {res!r}")


# ---------------------------------------------------------------------------
# Step 1: the owner account.
# ---------------------------------------------------------------------------
# POST /api/onboarding/users is unauthenticated and works exactly once. All
# five fields are required (the schema is PREVENT_EXTRA, so no extras either).
# `language` must be real — a bogus one KeyErrors into a 500 on the
# default-area translation lookup.
auth_code = None
try:
    _, res = call("/api/onboarding/users", "POST", {
        "name": os.environ["HA_ADMIN_NAME"],
        "username": os.environ["HA_ADMIN_USER"],
        "password": os.environ["HA_ADMIN_PASSWORD"],
        "client_id": CLIENT_ID,
        "language": "en",
    })
    auth_code = (res or {}).get("auth_code")
    change(f"home assistant owner {os.environ['HA_ADMIN_USER']} created")
except urllib.error.HTTPError as e:
    if e.code not in (403, 404):
        sys.exit(f"automation-init: FATAL: onboarding/users HTTP {e.code}: "
                 f"{detail(e)}")
    log(f"onboarding already done (HTTP {e.code}) - no change")

if auth_code is None:
    # Already onboarded. Log in with the seeded credentials instead of
    # stopping here: the MQTT config entry below has to be REACHABLE on a
    # re-run, or a first run that created the owner and then failed at the
    # broker step could never be repaired by redeploying. Convergent, not
    # once-only.
    try:
        _, flow = call("/auth/login_flow", "POST", {
            "client_id": CLIENT_ID,
            "handler": ["homeassistant", None],
            "redirect_uri": CLIENT_ID,
        })
        flow_id = (flow or {}).get("flow_id")
        if not flow_id:
            sys.exit(f"automation-init: FATAL: login flow returned no "
                     f"flow_id: {flow!r}")
        _, res = call(f"/auth/login_flow/{flow_id}", "POST", {
            "client_id": CLIENT_ID,
            "username": os.environ["HA_ADMIN_USER"],
            "password": os.environ["HA_ADMIN_PASSWORD"],
        })
        auth_code = (res or {}).get("result")
    except urllib.error.HTTPError as e:
        sys.exit(f"automation-init: FATAL: login HTTP {e.code}: {detail(e)} "
                 f"(home assistant is onboarded but these credentials do not "
                 f"match its owner — did .env change after the first seed?)")
    if not auth_code:
        sys.exit(f"automation-init: FATAL: login produced no authorization "
                 f"code: {res!r}")
    onboarding_done = True
else:
    onboarding_done = False

# ---------------------------------------------------------------------------
# Step 2: exchange the code for a token. Same endpoint for both paths above.
# ---------------------------------------------------------------------------
try:
    _, tok = call("/auth/token", "POST", form={
        "grant_type": "authorization_code",
        "client_id": CLIENT_ID,
        "code": auth_code,
    })
except urllib.error.HTTPError as e:
    sys.exit(f"automation-init: FATAL: /auth/token HTTP {e.code}: {detail(e)} "
             f"(a JSON body here returns 400 unsupported_grant_type — this "
             f"endpoint is form-encoded)")

token = (tok or {}).get("access_token")
if not token:
    sys.exit(f"automation-init: FATAL: /auth/token returned no access_token: "
             f"{tok!r}")

# ---------------------------------------------------------------------------
# Steps 3-5: finish the wizard.
# ---------------------------------------------------------------------------
# core_config takes NO body in the current line — latitude/longitude/units are
# not parameters (older docs say otherwise). It does fire a few config flows
# as detached tasks, some of which need the internet; they fail harmlessly
# offline.
#
# integration needs {client_id, redirect_uri} and returns a second auth code
# that nothing here consumes — it exists so a UI client can pick up a session.
# Keep the two same-origin, or HA makes an outbound request to verify the
# redirect URI.
if not onboarding_done:
    for step, body in [
        ("core_config", None),
        ("analytics", None),
        ("integration", {"client_id": CLIENT_ID, "redirect_uri": CLIENT_ID}),
    ]:
        try:
            call(f"/api/onboarding/{step}", "POST", body, token=token)
            change(f"onboarding step {step} completed")
        except urllib.error.HTTPError as e:
            if e.code in (403, 404):
                log(f"onboarding step {step} already done (HTTP {e.code}) "
                    f"- no change")
            else:
                sys.exit(f"automation-init: FATAL: onboarding/{step} "
                         f"HTTP {e.code}: {detail(e)}")

# ---------------------------------------------------------------------------
# Step 6: the MQTT broker connection.
# ---------------------------------------------------------------------------
seed_mqtt(token)

log(f"done ({changes} change(s))")
PY
