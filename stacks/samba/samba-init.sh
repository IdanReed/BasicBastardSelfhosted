#!/bin/sh
# samba-init — refuse to start a file server that would look fine and be
# unusable. Checks nothing about Samba itself: it checks the things that, when
# wrong, produce a HEALTHY container serving nothing (the image's healthcheck
# is an anonymous SMB3 round trip and cannot see any of them).
#
# House rule: mutations log "samba-init: CHANGE: ...". This mutates nothing,
# so a correct run logs zero CHANGE lines by construction.
#
# Busybox sh in alpine:3.21 — no bashisms, no arrays. `printenv` reads the
# per-user password env vars by computed name.
set -eu

log() { echo "samba-init: $*"; }
die() { echo "samba-init: FATAL: $*" >&2; exit 1; }

# user:uid — MUST match config.yml's `auth:` uids and the DIR_NOTES rules for
# /mnt/slow/samba/personal/<user>. All share gid 1000 (the `shared` tree).
USERS="idan:1000 alondra:1001 cale:1002 zach:1003 rylan:1004 cameron:1005 justin:1006"
WANT_GID="${SAMBA_SHARE_GID:-1000}"

# ---------------------------------------------------------------------------
# 1. Every user's password must exist and be non-placeholder.
#
# Prevents: envsubst turns an unset var into "" with no warning, `smbpasswd
# -a -s` fails, the user never enters the passdb — and the container reports
# healthy forever (anonymous probe) while `map to guest = bad user` treats
# the missing user as *guest*, not a rejection; only the share's
# `valid users` keeps it out. Each SAMBA_<USER>_PASSWORD is a copy_only twin
# of that user's Authentik password (secrets-gen/manifest.yaml user/*).
# ---------------------------------------------------------------------------
for entry in $USERS; do
  u=${entry%%:*}
  U=$(echo "$u" | tr 'a-z' 'A-Z')
  var="SAMBA_${U}_PASSWORD"
  pw=$(printenv "$var" 2>/dev/null || true)
  [ -n "$pw" ] || die "$var is empty or unset. The image would substitute an
  empty string into config.yml, fail to create user '$u', and then report
  HEALTHY with a share nobody can authenticate to. See .sops.env.example."
  case "$pw" in
    changeme_*) die "$var is still the committed placeholder. Hand-set a real
  (memorable) one via sopsedit — see .sops.env.example." ;;
  esac
done

# ---------------------------------------------------------------------------
# 2. The interface list must exist and must contain `lo`.
#
# SAMBA_INTERFACES emits both `interfaces = ...` and `bind interfaces only =
# yes`. Without `lo` the healthcheck (dials \\localhost) goes permanently
# unhealthy WHILE EVERY REAL CLIENT WORKS — the inverse failure of #1.
# ---------------------------------------------------------------------------
[ -n "${SAMBA_INTERFACES:-}" ] || die \
  "SAMBA_INTERFACES is empty or unset. It must name the interfaces smbd
  binds — the tailnet address is assigned at runtime and the NIC name is
  host-specific, so there is no safe default to fall back to."

case " $SAMBA_INTERFACES " in
  *" lo "*) : ;;
  *) die "SAMBA_INTERFACES ('$SAMBA_INTERFACES') does not include 'lo'.
  With 'bind interfaces only = yes' — which this variable also emits — smbd
  would not listen on loopback, the healthcheck would fail forever, and every
  real client would work perfectly. Add lo." ;;
esac

# ---------------------------------------------------------------------------
# 3. Every share directory's ownership must match config.yml's uid/gid.
#
# adduser -u creates the user IN the container; the files land on the host.
# Nothing connects the two but agreement between config.yml and the tmpfiles
# rules (DIR_NOTES in nixos/generate-stack-dirs.py). A mismatch is files
# nothing else in the fleet can read, discovered much later. A REFUSAL rather
# than a chown on purpose: silently taking ownership of a directory holding
# someone else's data is worse than not starting.
#
# `shared` is 1000:1000 (idan + group). Each `personal/<user>` is <uid>:1000.
# ---------------------------------------------------------------------------
check_dir() {  # path want_uid want_gid label
  path="$1"; wu="$2"; wg="$3"; label="$4"
  [ -d "$path" ] || die "$label ($path) is not mounted — the bind mount is missing"
  gu=$(stat -c %u "$path"); gg=$(stat -c %g "$path")
  if [ "$gu" != "$wu" ] || [ "$gg" != "$wg" ]; then
    die "$label is owned $gu:$gg but config.yml uses $wu:$wg. Files written
  over SMB would be unreadable to everything else. Fix the DIR_NOTES entry for
  $path in nixos/generate-stack-dirs.py (then rerun ./nixos/generate-stack-dirs.sh
  — stack-dirs.nix is generated, hand-edits fail the lint), or the uid in
  config.yml — but make them agree."
  fi
}

# shared tree (mounted at /share)
check_dir /share 1000 "$WANT_GID" "shared tree"

# per-user personal dirs (mounted under /personal/<user>)
for entry in $USERS; do
  u=${entry%%:*}; uid=${entry##*:}
  check_dir "/personal/$u" "$uid" "$WANT_GID" "personal/$u"
done

log "7 passwords present, interfaces include lo, shared + personal dirs own uid contract holds"
log "done"
