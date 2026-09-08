#!/bin/sh
# scan-downloads.sh — ClamAV poll-watcher for the downloads tree. Runs in a
# second container from the same clamav image, talking to clamd over TCP; both
# see targets at /data/downloads so path-based scan requests resolve.
#
# Every $SCAN_INTERVAL_SECONDS: scan files modified since the last pass;
# infected files are quarantined and ntfy'd, clean ones left alone. The
# `audiobooks` category is handled as whole entries instead — one verdict per
# torrent, and a clean one is moved into the books stack's drop directory.
#
# QUARANTINE IS AN INODE OPERATION, NOT A RENAME. /mnt/slow is one filesystem,
# so *arr imports are hardlinks and a bare `mv` into .quarantine leaves the
# inode reachable through /data/media. Nothing sequences import against scan,
# so that window happens in ordinary operation: the original is renamed into
# .quarantine as evidence and every OTHER link to that inode is unlinked.
#
# Poll rather than inotify: simpler and immune to watch exhaustion. Filenames
# containing newlines are not handled.
set -u

# Whole /data, not just downloads: the other links live in /data/media.
DATA=/data
DOWNLOADS="$DATA/downloads"
QUARANTINE="$DOWNLOADS/.quarantine"
AUDIOBOOKS="$DOWNLOADS/audiobooks"
DROP="${AUDIOBOOK_DROP_DIR:-/drop}"
MARKER=/state/last-scan
SIZES=/state/audiobook-sizes
CONF=/tmp/clamd-client.conf
NTFY_URL="${NTFY_URL:-http://ntfy/media}"
INTERVAL="${SCAN_INTERVAL_SECONDS:-60}"

mkdir -p "$QUARANTINE" /state "$SIZES"
printf 'TCPSocket 3310\nTCPAddr clamav\n' > "$CONF"

# busybox wget; failure to notify must never stop quarantining.
notify() {
  wget -q -O /dev/null --post-data "$1" "$NTFY_URL" \
    || echo "scan: WARN: ntfy notification failed: $1" >&2
}

# clamdscan rc: 0 clean, 1 infected, 2 error (unreadable, clamd hiccup).
scan_one() {
  clamdscan --config-file="$CONF" --no-summary "$1" >/dev/null 2>&1
}

# Quarantine ONE file, inode-effectively. See the header.
quarantine_file() {
  qf=$1
  # Inode BEFORE the move: across filesystems `mv` becomes copy+unlink and
  # $qdest would carry a new inode.
  qino=$(stat -c %i "$qf" 2>/dev/null || echo "")
  qlinks=$(stat -c %h "$qf" 2>/dev/null || echo "")

  qdest="$QUARANTINE/$(basename "$qf").$(date +%s)"
  if ! mv -f "$qf" "$qdest"; then
    echo "scan: ERROR: could not quarantine $qf" >&2
    return 1
  fi
  echo "scan: INFECTED $qf -> $qdest"
  notify "ClamAV quarantined: $qf"

  if [ -z "$qino" ]; then
    echo "scan: ERROR: could not read the inode of $qf — other hardlinks (if any) NOT purged" >&2
    return 0
  fi
  # One link: the move was the whole quarantine — skip the tree walk.
  [ "${qlinks:-1}" -gt 1 ] 2>/dev/null || return 0

  # -xdev: hardlinks cannot cross filesystems; the prune is what keeps the
  # evidence copy. Status checked and stderr NOT suppressed: a find that
  # cannot run this expression looks exactly like "no other links".
  if ! others=$(find "$DATA" -xdev -path "$QUARANTINE" -prune -o \
    -type f -inum "$qino" -print); then
    echo "scan: ERROR: hardlink walk for inode $qino failed — INFECTED CONTENT MAY STILL BE REACHABLE" >&2
    notify "ClamAV could not purge the hardlinks of $qf — check the library"
    return 0
  fi

  printf '%s\n' "$others" | while IFS= read -r ql; do
    [ -n "$ql" ] || continue
    # Belt and braces over the prune: never unlink the evidence.
    case "$ql" in "$QUARANTINE"/*) continue ;; esac
    if rm -f "$ql"; then
      echo "scan: UNLINKED $ql (hardlink to quarantined inode $qino)"
      notify "ClamAV unlinked a hardlink to a quarantined file: $ql"
    else
      echo "scan: ERROR: could not unlink $ql (inode $qino) — INFECTED CONTENT IS STILL REACHABLE THERE" >&2
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# Audiobook promotion (ServerNotes/designs/audiobook-acquisition.md)
# ---------------------------------------------------------------------------
# No *arr imports this category, so this loop is also its importer. WHOLE
# ENTRIES, one verdict per torrent — a per-file quarantine could strip the
# infected track and leave the rest looking promotable. An entry must settle
# (identical `du -s` on two passes) before it is scanned, because qBittorrent
# may still be writing. Accepted cost: a promoted entry leaves the download
# tree, so seeding stops.
promote_audiobooks() {
  [ -d "$AUDIOBOOKS" ] || return 0
  if [ ! -d "$DROP" ]; then
    echo "scan: WARN: drop dir $DROP is missing — audiobook promotion skipped" >&2
    return 0
  fi
  # Settle records are keyed on the basename, so one left behind by an entry
  # that vanished without a verdict (deleted in qbit, moved by hand) would let
  # a LATER torrent of the same name look settled on its first pass and be
  # scanned mid-download. Sweep first.
  for stale in "$SIZES"/*; do
    [ -e "$stale" ] || continue
    [ -e "$AUDIOBOOKS/$(basename "$stale")" ] || rm -f "$stale"
  done

  for entry in "$AUDIOBOOKS"/*; do
    [ -e "$entry" ] || continue          # no glob match
    name=$(basename "$entry")
    case "$name" in .*) continue ;; esac # qbit scratch, if any

    # --- settle: identical `du -s` on two consecutive passes ---------------
    size=$(du -s "$entry" 2>/dev/null | cut -f1)
    prev_file="$SIZES/$name"
    prev=$(cat "$prev_file" 2>/dev/null)
    printf '%s\n' "$size" > "$prev_file"
    if [ -z "$size" ] || [ "$size" != "$prev" ]; then
      echo "scan: audiobook '$name' still settling (${prev:-new} -> $size blocks)"
      continue
    fi

    # --- verdict for the WHOLE entry --------------------------------------
    # Pipeline `while` = subshell, so the verdict travels through a file.
    vf="/tmp/audiobook-verdict.$$"
    : > "$vf"
    find "$entry" -type f -print | while IFS= read -r f; do
      scan_one "$f"
      case $? in
        0) ;;
        1) echo I >> "$vf"; quarantine_file "$f" ;;
        *) echo E >> "$vf"; echo "scan: ERROR: clamdscan failed on $f" >&2 ;;
      esac
    done

    if grep -q I "$vf" 2>/dev/null; then
      # Condemn the whole entry: infected files are already quarantined;
      # what is left must not look promotable next pass.
      dest="$QUARANTINE/$name.$(date +%s)"
      if [ ! -e "$entry" ]; then
        # Single-file torrent: quarantine_file already took the whole entry.
        echo "scan: INFECTED audiobook '$name' -> already quarantined as a file (NOT promoted)"
        notify "ClamAV quarantined an audiobook: $name"
      elif mv -f "$entry" "$dest"; then
        echo "scan: INFECTED audiobook '$name' -> $dest (NOT promoted)"
        notify "ClamAV quarantined an audiobook: $name"
      else
        echo "scan: ERROR: could not quarantine audiobook entry $entry" >&2
      fi
      rm -f "$prev_file"
    elif grep -q E "$vf" 2>/dev/null; then
      echo "scan: audiobook '$name' had scan errors — leaving it for the next pass" >&2
    else
      dest="$DROP/$name"
      [ -e "$dest" ] && dest="$DROP/$name.$(date +%s)"
      # Same filesystem => rename: the entry appears complete or not at all.
      if mv -f "$entry" "$dest"; then
        echo "scan: PROMOTED clean audiobook '$name' -> $dest"
        notify "Audiobook passed the ClamAV scan and is in the drop dir: $name"
      else
        echo "scan: ERROR: could not promote audiobook $entry -> $dest" >&2
      fi
      rm -f "$prev_file"
    fi
    rm -f "$vf"
  done
}

echo "scan: waiting for clamd at clamav:3310"
until clamdscan --config-file="$CONF" --ping 1 >/dev/null 2>&1; do
  sleep 5
done
echo "scan: clamd up; polling $DOWNLOADS every ${INTERVAL}s"

while :; do
  # Timestamp BEFORE scanning, so files modified mid-pass are re-scanned.
  # Back-dated 2s because `find -newer` is a strict '>' at 1s resolution: a
  # file whose mtime lands in the marker's own second would never be scanned.
  touch -d "@$(( $(date +%s) - 2 ))" /tmp/scan-pass

  # A future-dated marker (clock step, restored /state) would make `-newer`
  # exclude every file forever, silently. Notice it and start over.
  if [ -f "$MARKER" ] && [ -n "$(find "$MARKER" -newer /tmp/scan-pass)" ]; then
    echo "scan: WARN: $MARKER is dated in the future (clock step?) — discarding it and rescanning everything" >&2
    rm -f "$MARKER"
  fi

  # Errors travel through a file (subshell again); the marker needs them.
  ef="/tmp/scan-errors.$$"
  : > "$ef"

  # downloads/audiobooks is pruned here; promote_audiobooks handles it.
  # .incomplete is deliberately NOT pruned: qBittorrent RENAMES a finished
  # file out of it, and a rename keeps the mtime — so a file scanned only at
  # its final path could be older than the marker and never scanned at all.
  # Scanning in .incomplete is what closes that hole.
  #
  # Collected into a variable so the pass can say how many candidates it
  # found — otherwise a dead loop and a quiet tree look identical.
  if [ -f "$MARKER" ]; then
    candidates=$(find "$DOWNLOADS" \( -path "$QUARANTINE" -o -path "$AUDIOBOOKS" \) -prune \
      -o -type f -newer "$MARKER" -print)
  else
    candidates=$(find "$DOWNLOADS" \( -path "$QUARANTINE" -o -path "$AUDIOBOOKS" \) -prune \
      -o -type f -print)
  fi
  n=$(printf '%s' "$candidates" | grep -c . || true)
  if [ "${n:-0}" -gt 0 ] 2>/dev/null; then
    echo "scan: pass: $n file(s) modified since the last pass"
    printf '%s\n' "$candidates" | while IFS= read -r f; do
      [ -n "$f" ] || continue
      scan_one "$f"
      rc=$?
      if [ "$rc" = 1 ]; then
        quarantine_file "$f"
      elif [ "$rc" != 0 ]; then
        # 2 = scan error: record it, so the marker does not advance.
        echo E >> "$ef"
        echo "scan: ERROR: clamdscan rc=$rc on $f" >&2
      fi
    done
  fi

  promote_audiobooks

  # Advance the marker ONLY on an error-free pass: a file that hit a clamd
  # hiccup would otherwise be -newer-excluded from every later pass.
  if [ -s "$ef" ]; then
    echo "scan: WARN: pass had scan errors — not advancing the marker, so the window is re-scanned next pass" >&2
    rm -f /tmp/scan-pass
  else
    mv /tmp/scan-pass "$MARKER"
  fi
  rm -f "$ef"
  sleep "$INTERVAL"
done
