#!/bin/sh
# passwd-init — generates /mosquitto/config/passwd before the broker starts
# (annex §3.2). Runs in the eclipse-mosquitto image itself, as root.
#
# Why this image and not alpine: mosquitto_passwd is already here, so there is
# no `apk add` in the boot path. That is finding #4 — backrest's config-init
# used to install gettext at container start, and a registry outage at boot
# took the whole backup stack down with it.
#
# Why it regenerates unconditionally rather than touch-once: this is what
# makes secret rotation work. Rotating MQTT_*_PASSWORD in sops and
# re-deploying has to reach the broker, and the file is derived state with no
# runtime-owned content to preserve (contrast backrest's config.json, which
# the app itself writes to).
#
# Contract:
#   - Unset, empty, or still-changeme_ credentials are a HARD error, BEFORE
#     the broker starts. A broker that silently comes up with two of three
#     accounts is worse than one that refuses.
#   - `-H sha512-pbkdf2` is passed EXPLICITLY. mosquitto 2.1 changed the
#     default to argon2id, which a 2.0.x broker cannot read — being explicit
#     makes this artifact version-independent in both directions.
#   - `-c` (create/OVERWRITE) on the first call only; the rest append.
set -eu

PASSWD=/mosquitto/config/passwd
TMP="$PASSWD.tmp"

fail() {
    echo "passwd-init: FATAL: $1" >&2
    exit 1
}

check() {
    # $1 = variable name. Empty or a leftover placeholder are both failures:
    # the .sops.env.example ships changeme_ values, and a stack deployed with
    # the example copied verbatim should not start.
    eval "value=\${$1:-}"
    [ -n "$value" ] || fail "$1 is unset or empty in .env (decrypt race? finding #11)"
    case "$value" in
        changeme_*) fail "$1 is still the .sops.env.example placeholder" ;;
    esac
}

# FRIGATE_MQTT_PASSWORD carries the FRIGATE_ prefix because Frigate's own
# config substitution only sees FRIGATE_-prefixed variables — so the broker
# side reads the same single key rather than the stack carrying two names for
# one value.
for var in FRIGATE_MQTT_PASSWORD MQTT_HA_PASSWORD MQTT_HEALTHCHECK_PASSWORD; do
    check "$var"
done

# THIS ONESHOT REGENERATES UNCONDITIONALLY, and is the one place in the fleet
# where a re-run legitimately logs a CHANGE line. That is a deliberate choice
# between two imperfect options:
#
#   - mosquitto_passwd SALTS every hash, so the output is never byte-identical
#     between runs and `cmp` cannot answer "did anything actually change?".
#   - Answering it anyway means storing a digest of the INPUT passwords beside
#     the file — which lives under /mnt/fast, which backrest backs up. That
#     ships an offline-crackable artifact to a third-party storage box to save
#     a log line. An unsalted digest of an operator-chosen password is worth
#     considerably more to an attacker than the pbkdf2 hashes it sits next to.
#
# So: no sidecar, regenerate every time, and the automation suite exempts this
# container from its zero-CHANGE assertion with the same reasoning. Rotation
# works for free as a consequence.

# Built under a tmpfile and renamed, so the broker can never observe a
# half-written password file if this is re-run while it is up.
rm -f "$TMP"
mosquitto_passwd -H sha512-pbkdf2 -c -b "$TMP" frigate       "$FRIGATE_MQTT_PASSWORD"
mosquitto_passwd -H sha512-pbkdf2    -b "$TMP" homeassistant "$MQTT_HA_PASSWORD"
mosquitto_passwd -H sha512-pbkdf2    -b "$TMP" healthcheck   "$MQTT_HEALTHCHECK_PASSWORD"

# 1883 is the uid the broker drops to. World-readable or wrongly-owned
# password files only WARN today ("Future versions will refuse to load this
# file"), so this is set correctly now rather than discovered later.
chown 1883:1883 "$TMP"
chmod 600 "$TMP"
mv "$TMP" "$PASSWD"

echo "passwd-init: CHANGE: rendered password file for 3 accounts"
