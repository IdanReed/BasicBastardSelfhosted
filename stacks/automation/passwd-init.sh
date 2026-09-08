#!/bin/sh
# passwd-init — generates /mosquitto/config/passwd before the broker starts.
# Runs in the eclipse-mosquitto image itself, as root, so there is no
# `apk add` in the boot path.
#
# Contract:
#   - Unset, empty or still-changeme_ credentials are a HARD error before the
#     broker starts: coming up with two of three accounts is worse than
#     refusing.
#   - `-H sha512-pbkdf2` is EXPLICIT because mosquitto 2.1 changed the default
#     to argon2id, which a 2.0.x broker cannot read.
#   - Passwords never appear in argv; see the staging block below.
#   - Regenerates unconditionally — the file is derived state with no
#     runtime-owned content to preserve.
set -eu

# Every file created here holds credentials at some point in its life.
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
    [ -n "$value" ] || fail "$1 is unset or empty in .env (decrypt race?)"
    case "$value" in
        changeme_*) fail "$1 is still the .sops.env.example placeholder" ;;
    esac
    # ':' is the field separator in the staged file below, and
    # mosquitto_passwd -U would silently keep only the part before it.
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

# The one oneshot in the fleet where a re-run legitimately logs a CHANGE line
# (the automation suite exempts it): mosquitto_passwd salts every hash, so
# `cmp` cannot answer "did anything change?" and answering it would mean
# storing a digest of the input passwords on a backed-up volume.

# NOT `-b <password>`: these processes live in the host PID namespace, where
# /proc/<pid>/cmdline is world-readable. `mosquitto_passwd -U` hashes a
# plaintext `user:password` file IN PLACE, so nothing secret is ever an
# argument. That plaintext stages in the container's private /tmp, never under
# /mosquitto/config — which is the /mnt/fast bind backrest ships offsite.
STAGE=/tmp/passwd.stage
# "$STAGE.tmp" too: -U rewrites through a sibling tmpfile and only unlinks it
# on success, so a failed rehash would leave the plaintext behind.
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

# 🚨 POST-CONDITION, load-bearing rather than belt-and-braces: if -U ever
# stops rehashing, the stage file still holds PLAINTEXT and installing it
# would hand every credential to the broker's config dir in the clear. `$7$`
# is the sha512-pbkdf2 marker.
hashed="$(grep -cF ':$7$' "$STAGE" || true)"
if [ "$hashed" != 3 ]; then
    fail "mosquitto_passwd -U produced $hashed of 3 sha512-pbkdf2 hashes; refusing to install a password file that may still be plaintext"
fi

# Copied onto a tmpfile on the DESTINATION filesystem so the install stays an
# atomic rename; a `mv` out of /tmp would degrade to copy-then-unlink.
cp "$STAGE" "$TMP"

# 1883 is the uid the broker drops to. A wrongly-owned password file only
# WARNs today; future versions will refuse to load it.
chown 1883:1883 "$TMP"
chmod 600 "$TMP"
mv "$TMP" "$PASSWD"

echo "passwd-init: CHANGE: rendered password file for 3 accounts"
