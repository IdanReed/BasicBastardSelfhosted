#!/bin/sh
# passwd-init — generates /mosquitto/config/passwd before the broker starts
# (annex §3.2). Runs in the eclipse-mosquitto image itself, as root.
#
# This image, not alpine: mosquitto_passwd is already here, so no `apk add`
# in the boot path (finding #4 — a registry outage at boot must not take the
# stack down).
#
# Regenerates unconditionally — see the block below; the file is derived
# state with no runtime-owned content to preserve (contrast backrest's
# config.json, which the app itself writes).
#
# Contract:
#   - Unset, empty, or still-changeme_ credentials are a HARD error, BEFORE
#     the broker starts. A broker that silently comes up with two of three
#     accounts is worse than one that refuses.
#   - `-H sha512-pbkdf2` is passed EXPLICITLY. mosquitto 2.1 changed the
#     default to argon2id, which a 2.0.x broker cannot read — being explicit
#     makes this artifact version-independent in both directions.
#   - Passwords never appear in argv. See the staging block below.
set -eu

# Every file this script creates holds credentials at some point in its life;
# born 0600 rather than chmod'd to it after the content is already on disk.
umask 077

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
    # ':' is the field separator in the staged user:password file below, and
    # mosquitto_passwd -U would silently keep only the part before it — a
    # broker running on half a password, with no error anywhere. Refusing is
    # the only honest option; pick a password without a colon.
    case "$value" in
        *:*) fail "$1 contains a ':', which mosquitto_passwd -U reads as the field separator" ;;
    esac
}

# FRIGATE_MQTT_PASSWORD carries the FRIGATE_ prefix because Frigate's own
# config substitution only sees FRIGATE_-prefixed variables — so the broker
# side reads the same single key rather than the stack carrying two names for
# one value.
for var in FRIGATE_MQTT_PASSWORD MQTT_HA_PASSWORD MQTT_HEALTHCHECK_PASSWORD; do
    check "$var"
done

# REGENERATES UNCONDITIONALLY — the one oneshot in the fleet where a re-run
# legitimately logs a CHANGE line (the automation suite exempts it from the
# zero-CHANGE assertion). mosquitto_passwd SALTS every hash, so `cmp` cannot
# answer "did anything change?" — and answering it would mean storing a
# digest of the INPUT passwords under /mnt/fast, an offline-crackable
# artifact shipped to a third-party storage box to save a log line. Rotation
# works for free as a consequence.

# NOT `-b <password>`: processes here live in the host PID namespace, where
# /proc/<pid>/cmdline is world-readable — that form published all three MQTT
# passwords to every host uid (same narrowing as backup-prepare.sh's
# MYSQL_PWD). `mosquitto_passwd -U` hashes a plaintext `user:password` file
# IN PLACE, so nothing secret is ever an argument.
#
# The plaintext stages in the container's private /tmp, never under
# /mosquitto/config — that path is the /mnt/fast bind, which backrest ships
# to a third-party storage box. Only the HASHED result crosses over.
STAGE=/tmp/passwd.stage
# "$STAGE.tmp" too: mosquitto_passwd -U rewrites through a sibling <file>.tmp
# and only unlinks it on success, so a failed rehash would otherwise leave the
# plaintext behind.
trap 'rm -f "$STAGE" "$STAGE.tmp"' EXIT

rm -f "$STAGE" "$STAGE.tmp" "$TMP"
{
    printf '%s:%s\n' frigate       "$FRIGATE_MQTT_PASSWORD"
    printf '%s:%s\n' homeassistant "$MQTT_HA_PASSWORD"
    printf '%s:%s\n' healthcheck   "$MQTT_HEALTHCHECK_PASSWORD"
} > "$STAGE"

if ! mosquitto_passwd -H sha512-pbkdf2 -U "$STAGE"; then
    fail "mosquitto_passwd -U failed; the existing password file was left alone"
fi

# 🚨 POST-CONDITION, and it is load-bearing rather than belt-and-braces: if -U
# ever stops rehashing — unsupported, or -H rejected alongside it — the stage
# file still holds the PLAINTEXT passwords, and installing it would hand every
# credential to the broker's config dir in the clear. `$7$` is the
# sha512-pbkdf2 marker (`$6$` is plain sha512); three lines, three hashes.
hashed="$(grep -cF ':$7$' "$STAGE" || true)"
if [ "$hashed" != 3 ]; then
    fail "mosquitto_passwd -U produced $hashed of 3 sha512-pbkdf2 hashes; refusing to install a password file that may still be plaintext"
fi

# Copied onto a tmpfile on the DESTINATION filesystem so the install below is
# still an atomic rename: a `mv` straight out of /tmp would cross filesystems
# and degrade to copy-then-unlink, which the broker can observe half-written.
cp "$STAGE" "$TMP"

# 1883 is the uid the broker drops to. World-readable or wrongly-owned
# password files only WARN today ("Future versions will refuse to load this
# file"), so this is set correctly now rather than discovered later.
chown 1883:1883 "$TMP"
chmod 600 "$TMP"
mv "$TMP" "$PASSWD"

echo "passwd-init: CHANGE: rendered password file for 3 accounts"
