# quarantine.sh — the one quarantine both download checks use, sourced by
# scan-downloads.sh (ClamAV) and probe-downloads.sh (ffprobe). POSIX sh: the
# first runs in the Alpine clamav image, the second in Debian's.
#
# The caller sets, before sourcing:
#   DATA        the whole tree the other hardlinks live in (/data)
#   QUARANTINE  the evidence directory, inside DATA
#   NTFY_URL    where notifications are posted
#   Q_TAG       the log prefix ("scan", "probe")
#   Q_WHO       who is speaking in notifications ("ClamAV", "ffprobe")
#
# QUARANTINE IS AN INODE OPERATION, NOT A RENAME. /mnt/slow is one filesystem,
# so *arr imports are hardlinks and a bare `mv` into .quarantine leaves the
# inode reachable through /data/media. Nothing sequences import against a
# check, so that window happens in ordinary operation: the original is renamed
# into .quarantine as evidence and every OTHER link to that inode is unlinked.

# A failure to notify must never stop quarantining. busybox wget in the clamav
# image, curl in Jellyfin's (which has no wget).
notify() {
  if command -v wget >/dev/null 2>&1; then
    wget -q -O /dev/null --post-data "$1" "$NTFY_URL"
  else
    curl -fsS -o /dev/null --max-time 30 --data-binary "$1" "$NTFY_URL"
  fi || echo "$Q_TAG: WARN: ntfy notification failed: $1" >&2
}

# quarantine_file FILE VERDICT [REASON] — quarantine ONE file,
# inode-effectively. VERDICT is the log word (INFECTED, REJECTED).
quarantine_file() {
  qf=$1
  qverdict=$2
  qwhy=${3:-}
  # Inode BEFORE the move: across filesystems `mv` becomes copy+unlink and
  # $qdest would carry a new inode.
  qino=$(stat -c %i "$qf" 2>/dev/null || echo "")
  qlinks=$(stat -c %h "$qf" 2>/dev/null || echo "")

  qdest="$QUARANTINE/$(basename "$qf").$(date +%s)"
  if ! mv -f "$qf" "$qdest"; then
    echo "$Q_TAG: ERROR: could not quarantine $qf" >&2
    return 1
  fi
  echo "$Q_TAG: $qverdict $qf -> $qdest${qwhy:+ ($qwhy)}"
  notify "$Q_WHO quarantined: $qf${qwhy:+ - $qwhy}"

  if [ -z "$qino" ]; then
    echo "$Q_TAG: ERROR: could not read the inode of $qf — other hardlinks (if any) NOT purged" >&2
    return 0
  fi
  # One link: the move was the whole quarantine — skip the tree walk.
  [ "${qlinks:-1}" -gt 1 ] 2>/dev/null || return 0

  # -xdev: hardlinks cannot cross filesystems; the prune is what keeps the
  # evidence copy. Status checked and stderr NOT suppressed: a find that
  # cannot run this expression looks exactly like "no other links".
  if ! others=$(find "$DATA" -xdev -path "$QUARANTINE" -prune -o \
    -type f -inum "$qino" -print); then
    echo "$Q_TAG: ERROR: hardlink walk for inode $qino failed — QUARANTINED CONTENT MAY STILL BE REACHABLE" >&2
    notify "$Q_WHO could not purge the hardlinks of $qf — check the library"
    return 0
  fi

  printf '%s\n' "$others" | while IFS= read -r ql; do
    [ -n "$ql" ] || continue
    # Belt and braces over the prune: never unlink the evidence.
    case "$ql" in "$QUARANTINE"/*) continue ;; esac
    if rm -f "$ql"; then
      echo "$Q_TAG: UNLINKED $ql (hardlink to quarantined inode $qino)"
      notify "$Q_WHO unlinked a hardlink to a quarantined file: $ql"
    else
      echo "$Q_TAG: ERROR: could not unlink $ql (inode $qino) — QUARANTINED CONTENT IS STILL REACHABLE THERE" >&2
    fi
  done
  return 0
}
