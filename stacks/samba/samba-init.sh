#!/bin/sh
# samba-init — refuse to start a file server that would look fine and be
# unusable. It checks nothing about Samba itself, only the things that produce
# a HEALTHY container serving nothing; the image's healthcheck is an anonymous
# SMB3 round trip and cannot see any of them.
#
# Mutates nothing, so it logs zero CHANGE lines by construction. Busybox sh:
# no bashisms, and `printenv` reads the per-user vars by computed name.
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
# envsubst turns an unset var into "" with no warning, `smbpasswd -a -s` then
# fails, the user never enters the passdb, and the container stays healthy
# while `map to guest = bad user` treats them as *guest* rather than
# rejecting — only the share's `valid users` keeps them out.
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
# The list itself is required: there is no safe default (runtime tailnet
# address, host-specific NIC name). The `lo` half is belt-and-braces while
# config.yml overrides `bind interfaces only` to no — with it back at yes,
# omitting `lo` makes the healthcheck (which dials \\localhost) permanently
# unhealthy while every real client works, the inverse failure of #1.
# ---------------------------------------------------------------------------
[ -n "${SAMBA_INTERFACES:-}" ] || die \
  "SAMBA_INTERFACES is empty or unset. It must name the interfaces smbd
  binds — the tailnet address is assigned at runtime and the NIC name is
  host-specific, so there is no safe default to fall back to."

case " $SAMBA_INTERFACES " in
  *" lo "*) : ;;
  *) die "SAMBA_INTERFACES ('$SAMBA_INTERFACES') does not include 'lo'.
  This variable also emits 'bind interfaces only = yes'; config.yml currently
  overrides that to no, but if it is ever restored smbd stops listening on
  loopback, the healthcheck fails forever, and every real client keeps
  working. Add lo." ;;
esac

# ---------------------------------------------------------------------------
# 3. Every share directory's ownership must match config.yml's uid/gid.
#
# adduser -u creates the user in the container; the files land on the host,
# and nothing connects the two but agreement between config.yml and the
# tmpfiles rules (DIR_NOTES in nixos/generate-stack-dirs.py). A refusal rather
# than a chown: silently taking ownership of someone else's data is worse
# than not starting.
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

log "$(echo "$USERS" | wc -w) passwords present, interfaces include lo, shared + personal dirs hold the uid contract"
log "done"
