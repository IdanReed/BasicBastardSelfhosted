#!/bin/sh
# Headless first-run and SSO for OnlyOffice DocSpace, in two steps:
#
#   1. The setup wizard (annex §5): PUT /api/2.0/settings/wizard/complete.
#      Both things a script would normally lack are handed out by the
#      UNAUTHENTICATED GET /api/2.0/settings, because the wizard page needs
#      them before any account exists: `wizardToken` (populated only while the
#      wizard is incomplete — which is what makes this idempotent for free) and
#      the PBKDF2 `passwordHash` params.
#   2. SAML SSO against Authentik: POST /api/2.0/settings/ssov2, as the owner.
#      The IdP half is headscale-vps/authentik/blueprints/custom/docspace-saml.yaml.
#
# Every mutation logs "docspace-init: CHANGE: ...". A second run — every
# redeploy reruns this container — must log ZERO change lines.
set -eu

python3 - <<'PY'
import base64
import binascii
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

DS = "http://docspace:80"


def log(msg):
    print(f"docspace-init: {msg}", flush=True)


def fatal(msg):
    print(f"docspace-init: FATAL: {msg}", flush=True)
    sys.exit(1)


def env(name):
    v = os.environ.get(name, "").strip()
    if not v:
        # An unset value means the .env did not decrypt, and an unfinished
        # wizard is reachable by anyone who can reach the port.
        fatal(f"{name} is unset or empty")
    return v


def request(url, *, method="GET", body=None, headers=None, timeout=60):
    data = None
    hdrs = dict(headers or {})
    if body is not None:
        data = json.dumps(body).encode()
        hdrs["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=hdrs, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read().decode(errors="replace").strip()
            return r.status, raw
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace").strip()


def unwrap(raw):
    # The API wraps every answer as {"response": ..., "status": ...}. Always a
    # dict, so a malformed body reads as "nothing there" rather than a crash.
    try:
        doc = json.loads(raw)
    except ValueError:
        return {}
    resp = doc.get("response") if isinstance(doc, dict) else None
    doc = resp if isinstance(resp, dict) else doc
    return doc if isinstance(doc, dict) else {}


def api_error(body):
    # The message only: these bodies can echo settings, never print them whole.
    try:
        err = (json.loads(body) or {}).get("error") or {}
        return str(err.get("message") or "")[:300]
    except (ValueError, AttributeError):
        return body[:120]


def wait_for_settings(tries=120, delay=5):
    for _ in range(tries):
        try:
            code, body = request(f"{DS}/api/2.0/settings", timeout=10)
            if code == 200 and body:
                return unwrap(body)
        except Exception:
            pass
        time.sleep(delay)
    fatal("GET /api/2.0/settings never answered")


email = env("DOCSPACE_ADMIN_EMAIL")
password = env("DOCSPACE_ADMIN_PASSWORD")
if len(password) < 12:
    fatal("DOCSPACE_ADMIN_PASSWORD must be at least 12 characters")


# Wizard
def complete_wizard(data):
    token = data.get("wizardToken")
    if not token:
        # Absence is the idempotency signal, not an error.
        log("wizard already completed - no change")
        return

    # Password hash
    # PBKDF2-HMAC-SHA256, salt taken as the UTF-8 BYTES of the salt string (not
    # hex-decoded), output as lowercase hex of size/8 bytes. `iterations` is
    # read from the response and never hardcoded: upstream's config key is
    # misspelled so the value is always the fallback today, but a fix upstream
    # would change it.
    ph = data.get("passwordHash") or {}
    try:
        salt = ph["salt"]
        size = int(ph["size"])
        iterations = int(ph["iterations"])
    except (KeyError, TypeError, ValueError):
        fatal(f"settings did not carry usable passwordHash parameters: {ph!r}")

    # ⚠ With core:password:salt unset the salt is DERIVED FROM THE MACHINE KEY,
    # so the stored hash is bound to APP_CORE_MACHINEKEY — which is why that
    # must come from sops rather than being auto-generated into the data volume.
    digest = hashlib.pbkdf2_hmac(
        "sha256", password.encode("utf-8"), salt.encode("utf-8"), iterations, size // 8
    )
    password_hash = binascii.hexlify(digest).decode().lower()

    code, body = request(
        f"{DS}/api/2.0/settings/wizard/complete",
        method="PUT",
        body={"email": email, "passwordHash": password_hash},
        headers={"confirm": token, "Authorization": token},
    )
    if code >= 300:
        fatal(f"PUT /api/2.0/settings/wizard/complete returned {code}: {body[:400]}")

    log(f"CHANGE: completed the setup wizard as {email}")

    # Post-condition: the token must be gone now. If it is not, the wizard did
    # not actually complete and the instance is still open to whoever reaches it.
    if wait_for_settings(tries=12, delay=5).get("wizardToken"):
        fatal("the wizard token is still present after completing the wizard")


complete_wizard(wait_for_settings())


# SAML SSO
# Everything about the IdP — entity id, SSO endpoint, signing certificate — is
# read from Authentik's own metadata on every run, so a re-keyed or rebuilt
# Authentik reaches DocSpace on the next redeploy and nothing is stored twice.
# ⚠ Until it does, every SSO login fails: ASC.SsoAuth (samlify) accepts a
# response only if the certificate inside its signature EQUALS a stored one.
# It never checks that certificate's dates, so expiry alone breaks nothing.
# Authentik is on another host: when anything on the way to it fails, the
# portal keeps the SSO settings it has (WARN, exit 0) — a first deploy with
# the VPS down boots local-login-only and the next redeploy finishes the job.
#
# 🚨 The metadata URL 302s into /api/v3/providers/saml/<pk>/metadata/, which
# the VPS Caddy serves only to tailnet sources — publicly it is a 403. This
# container's extra_hosts pins auth.idanreed.com to the VPS's tailnet IP for
# exactly that reason.
IDP_METADATA = "https://auth.idanreed.com/application/saml/docspace/metadata/"
MD = "{urn:oasis:names:tc:SAML:2.0:metadata}"
DSIG = "{http://www.w3.org/2000/09/xmldsig#}"
BINDING_REDIRECT = "urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect"
BINDING_POST = "urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST"
NAMEID_EMAIL = "urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress"
RSA_SHA256 = "http://www.w3.org/2001/04/xmldsig-more#rsa-sha256"


def leave_sso(reason):
    log(f"WARN: {reason} - SSO settings left as they are")
    log("done")
    sys.exit(0)


def cert_body(pem):
    # Base64 DER with armour and whitespace gone — the comparable form.
    return re.sub(r"\s+", "", re.sub(r"-----[A-Z ]+-----", "", pem or ""))


def fingerprint(body):
    try:
        return "sha256 " + hashlib.sha256(base64.b64decode(body)).hexdigest()
    except (binascii.Error, ValueError):
        return "unparseable"


def fetch_idp_metadata(tries=3, delay=5):
    last = ""
    for attempt in range(tries):
        try:
            with urllib.request.urlopen(IDP_METADATA, timeout=20) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            last = f"HTTP {e.code}"
        except Exception as e:
            last = f"{type(e).__name__}: {e}"
        if attempt + 1 < tries:
            time.sleep(delay)
    leave_sso(f"cannot fetch the IdP metadata from {IDP_METADATA} ({last})")


def parse_idp_metadata(raw):
    try:
        root = ET.fromstring(raw)
    except ET.ParseError as e:
        leave_sso(f"the IdP metadata is not XML ({e})")
    idp = root.find(f"{MD}IDPSSODescriptor")
    if root.tag != f"{MD}EntityDescriptor" or idp is None:
        leave_sso("the IdP metadata has no IDPSSODescriptor")
    entity_id = (root.get("entityID") or "").strip()
    # The KeyDescriptor, not the first X509Certificate in the document: the
    # metadata's own enveloped signature carries one too.
    cert = ""
    for kd in idp.findall(f"{MD}KeyDescriptor"):
        if kd.get("use", "signing") == "signing":
            el = kd.find(f"{DSIG}KeyInfo/{DSIG}X509Data/{DSIG}X509Certificate")
            if el is not None and (el.text or "").strip():
                cert = cert_body(el.text)
                break
    sso = {el.get("Binding"): el.get("Location")
           for el in idp.findall(f"{MD}SingleSignOnService")}
    binding = BINDING_REDIRECT if sso.get(BINDING_REDIRECT) else BINDING_POST
    sso_url = (sso.get(binding) or "").strip()
    if not entity_id or not cert or not sso_url.startswith("https://"):
        leave_sso("the IdP metadata lacks an entity id, a signing certificate "
                  "or an https SSO endpoint - is a signing_kp set on the provider?")
    return entity_id, cert, binding, sso_url


def validated_certificate(body, tries=24, delay=5):
    # ASC.SsoAuth's own check, the one the settings page runs on upload: it
    # parses the certificate and returns the entry DocSpace stores, dates and
    # all. Retried, because the portal's healthcheck does not cover SsoAuth.
    pem = "-----BEGIN CERTIFICATE-----\n" + "\n".join(
        body[i:i + 64] for i in range(0, len(body), 64)) + "\n-----END CERTIFICATE-----"
    for _ in range(tries):
        try:
            code, raw = request(
                f"{DS}/sso/validatecerts", method="POST",
                body={"certs": [{"crt": pem, "action": "verification"}]}, timeout=30)
        except Exception:
            code, raw = None, ""
        if code == 200:
            try:
                entries = json.loads(raw)
                entry = entries[0] if isinstance(entries, list) and entries else {}
            except ValueError:
                entry = {}
            if cert_body(entry.get("crt")) != body:
                leave_sso("ASC.SsoAuth returned no usable certificate entry")
            return entry
        if code == 500:
            leave_sso(f"ASC.SsoAuth rejected the IdP certificate: {raw[:200]}")
        time.sleep(delay)
    leave_sso("ASC.SsoAuth never answered /sso/validatecerts")


def owner_token():
    # The password, not a hash: the server hashes it with the same parameters
    # the wizard step used. The token is never logged.
    try:
        code, raw = request(f"{DS}/api/2.0/authentication", method="POST",
                            body={"userName": email, "password": password})
    except Exception as e:
        leave_sso(f"POST /api/2.0/authentication failed ({type(e).__name__})")
    if code != 200:
        leave_sso(f"the owner could not sign in (HTTP {code}: {api_error(raw)}) - "
                  "was DOCSPACE_ADMIN_PASSWORD changed in the portal?")
    token = unwrap(raw).get("token")
    if not token:
        leave_sso("the owner sign-in returned no token - two-factor is on for "
                  "the owner, which this init cannot answer")
    return token


def get_path(doc, path):
    for key in path.split("."):
        doc = doc.get(key) if isinstance(doc, dict) else None
    return doc


def set_path(doc, path, value):
    keys = path.split(".")
    for key in keys[:-1]:
        if not isinstance(doc.get(key), dict):
            doc[key] = {}
        doc = doc[key]
    doc[keys[-1]] = value


def same(current, desired):
    # The API answers "" or null for an unset string and null for an unset
    # nullable bool; both mean the default.
    if isinstance(desired, bool):
        return bool(current) == desired
    return (current or "") == desired


def cert_pairs(doc):
    return [(cert_body(c.get("crt")), c.get("action"))
            for c in (doc.get("idpCertificates") or []) if isinstance(c, dict)]


def drift(doc, fields, cert):
    changed = [p for p, v in fields.items() if not same(get_path(doc, p), v)]
    if cert_pairs(doc) != [(cert, "verification")]:
        changed.append("idpCertificates")
    return changed


def configure_sso():
    entity_id, cert, binding, sso_url = parse_idp_metadata(fetch_idp_metadata())
    entry = validated_certificate(cert)

    fields = {
        "enableSso": True,
        "idpSettings.entityId": entity_id,
        "idpSettings.ssoUrl": sso_url,
        "idpSettings.ssoBinding": binding,
        # No SLO: with an SloUrl set, a DocSpace logout would also end the
        # user's Authentik session.
        "idpSettings.sloUrl": "",
        # Pairs with the provider's name_id_mapping: the NameID is the email,
        # which is how the wizard-seeded owner gets linked rather than cloned.
        "idpSettings.nameIdFormat": NAMEID_EMAIL,
        "idpCertificateAdvanced.verifyAlgorithm": RSA_SHA256,
        "idpCertificateAdvanced.verifyAuthResponsesSign": True,
        # The attribute names the blueprint's property mappings emit.
        "fieldMapping.firstName": "givenName",
        "fieldMapping.lastName": "sn",
        "fieldMapping.email": "mail",
        "spLoginLabel": "Authentik",
        # 🚨 Keeps the password form on the login page: the owner's local login
        # is the break-glass when Authentik is down.
        "hideAuthPage": False,
        # Users are created on first SSO login (DocSpace has no switch for it),
        # and left unverified they wait on an activation mail nothing sends.
        # Authentik's addresses are operator-set, never self-enrolled.
        "disableEmailVerification": True,
    }

    token = owner_token()
    auth = {"Authorization": token}
    try:
        def load():
            try:
                code, raw = request(f"{DS}/api/2.0/settings/ssov2", headers=auth)
            except Exception as e:
                leave_sso(f"GET /api/2.0/settings/ssov2 failed ({type(e).__name__})")
            if code != 200:
                # A portal that is not Standalone (APP_CORE_BASE_DOMAIN other
                # than localhost) answers here with "not allowed".
                leave_sso(f"GET /api/2.0/settings/ssov2 returned {code}: {api_error(raw)}")
            return unwrap(raw)

        current = load()
        changed = drift(current, fields, cert)
        if not changed:
            log("SAML SSO already configured - no change")
            return

        # A deep copy: set_path writes into the nested objects, and `current`
        # must still hold the old values for the CHANGE lines.
        payload = json.loads(json.dumps(current))
        payload.pop("lastModified", None)
        for path, value in fields.items():
            set_path(payload, path, value)
        payload["idpCertificates"] = [entry]

        try:
            code, raw = request(f"{DS}/api/2.0/settings/ssov2", method="POST",
                                body={"serializeSettings": json.dumps(payload)},
                                headers=auth)
        except Exception as e:
            fatal(f"POST /api/2.0/settings/ssov2 failed ({type(e).__name__})")
        if code >= 300:
            fatal(f"POST /api/2.0/settings/ssov2 returned {code}: {api_error(raw)}")

        for path in changed:
            if path == "idpCertificates":
                log(f"CHANGE: SSO IdP signing certificate -> {fingerprint(cert)}")
            else:
                log(f"CHANGE: SSO {path}: {get_path(current, path)!r} -> {fields[path]!r}")

        # Post-condition: a save that answered 200 but did not stick would
        # otherwise read as configured until somebody tries to log in.
        left = drift(load(), fields, cert)
        if left:
            fatal(f"SSO settings did not stick after saving: {', '.join(left)}")
    finally:
        # Best effort: ends the login event so the owner's session list does
        # not grow by one per deploy.
        try:
            request(f"{DS}/api/2.0/authentication/logout", method="POST", body={},
                    headers={**auth, "Cookie": f"asc_auth_key={token}"}, timeout=15)
        except Exception:
            pass


configure_sso()
log("done")
PY
