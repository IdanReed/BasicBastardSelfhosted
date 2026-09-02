#!/bin/sh
# samba-init — refuse to start a file server that would look fine and be
# unusable. Checks nothing about Samba itself: it checks the three things
# that, when wrong, produce a HEALTHY container serving nothing (the image's
# healthcheck is an anonymous SMB3 round trip and cannot see any of them).
#
# House rule: mutations log "samba-init: CHANGE: ...". This mutates nothing,
# so a correct run logs zero CHANGE lines by construction.
#
# Busybox sh in alpine:3.21 — no bashisms.
set -eu

log() { echo "samba-init: $*"; }
die() { echo "samba-init: FATAL: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. The password must exist and be non-empty.
#
# Prevents: envsubst turns an unset var into "" with no warning, `smbpasswd
# -a -s` fails, the user never enters the passdb — and the container reports
# healthy forever (anonymous probe) while `map to guest = bad user` treats
# the missing user as *guest*, not a rejection; only the share's
# `valid users` keeps it out.
# ---------------------------------------------------------------------------
[ -n "${SAMBA_IDAN_PASSWORD:-}" ] || die \
  "SAMBA_IDAN_PASSWORD is empty or unset. The image would substitute an empty
  string into config.yml, fail to create the user, and then report HEALTHY
  with a share nobody can authenticate to. See .sops.env.example."

case "$SAMBA_IDAN_PASSWORD" in
  changeme_*) die "SAMBA_IDAN_PASSWORD is still the committed placeholder.
  Generate a real one — .sops.env.example has the command." ;;
esac

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
# 3. The share directory's ownership must match config.yml's uid/gid.
#
# adduser -u creates the user IN the container; the files land on the host.
# Nothing connects the two but agreement between config.yml and the tmpfiles
# rule (DIR_NOTES in nixos/generate-stack-dirs.py). A mismatch is files
# nothing else in the fleet can read, discovered much later.
#
# A REFUSAL rather than a chown on purpose: silently taking ownership of a
# directory holding someone else's data is worse than not starting.
# ---------------------------------------------------------------------------
WANT_UID="${SAMBA_SHARE_UID:-1000}"
WANT_GID="${SAMBA_SHARE_GID:-1000}"

[ -d /share ] || die "/share is not mounted — the share bind mount is missing"

got_uid=$(stat -c %u /share)
got_gid=$(stat -c %g /share)
if [ "$got_uid" != "$WANT_UID" ] || [ "$got_gid" != "$WANT_GID" ]; then
  die "share directory is owned by $got_uid:$got_gid but config.yml creates
  the SMB user as $WANT_UID:$WANT_GID. Files written over SMB would be
  unreadable to everything else in the fleet. Fix the DIR_NOTES entry for
  /mnt/slow/samba/shared in nixos/generate-stack-dirs.py (then rerun
  ./nixos/generate-stack-dirs.sh — stack-dirs.nix is generated, hand-edits
  fail the lint), or the uid in config.yml — but make them agree."
fi

log "password present, interfaces include lo, share is $got_uid:$got_gid"
log "done"
