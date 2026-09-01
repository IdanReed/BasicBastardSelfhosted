#!/bin/sh
# scan-downloads.sh — ClamAV poll-watcher for the downloads tree (annex §5).
#
# Runs in a second container from the SAME pinned clamav/clamav image (so
# clamdscan is present without any apk at boot — finding #4), talking to clamd
# in the `clamav` service over TCP. Both containers see the scan targets at the
# same path (/data/downloads), so path-based scan requests resolve on clamd's
# side.
#
# Behaviour:
#   - every $SCAN_INTERVAL_SECONDS: scan files modified since the last pass
#     (first pass scans everything);
#   - infected  -> QUARANTINE BY INODE (see below) + ntfy POST. The arr
#     import then fails and Cleanuparr's strike system removes + blocklists
#     the release — the ClamAV->Cleanuparr interplay is deliberately indirect;
#   - clean     -> untouched (the media suite asserts both directions, EICAR
#     as the trigger);
#   - the `audiobooks` category is handled as WHOLE ENTRIES, one verdict per
#     torrent, and a clean entry is MOVED into the books stack's drop
#     directory (see "Audiobook promotion" below).
#
# QUARANTINE IS AN INODE OPERATION, NOT A RENAME  🚨
# --------------------------------------------------
# This used to be a bare `mv -f` into .quarantine. Within one filesystem —
# and /mnt/slow is deliberately ONE filesystem so that *arr imports are
# hardlinks, not copies (compose.yaml's layout header) — a rename moves a
# directory ENTRY and leaves the inode alone. Any hardlink an *arr had
# already created into /data/media still pointed at the infected inode: the
# scanner logged INFECTED, ntfy fired, and the malware was still in the
# library. Nothing sequences the two — the *arrs import on qBittorrent's
# completion signal, this loop polls every 60s — so that window is reachable
# in ordinary operation, and the old EICAR tests stayed green through it
# because they only asserted that .quarantine gained a file.
#
# So: after the original is renamed into .quarantine (which keeps the sample
# as evidence), every OTHER path sharing that inode under /data is unlinked
# and logged. The quarantined copy is the one link that survives, by
# construction — it is the only one the walk skips. Hardlink imports keep
# working exactly as before; they just stop outliving the verdict.
#
# Poll (find -newer) rather than inotify on purpose: simplest, test-friendly,
# and immune to watch-descriptor exhaustion on big trees. Filenames with
# newlines are not handled (find|read line protocol) — torrents do not
# produce them in practice.
set -u

# The WHOLE /data tree, not just downloads: unlinking the other links to an
# infected inode means reaching /data/media, which is where an *arr import
# puts them. clamd still only ever sees /data/downloads (its own mount is
# narrower and read-only) — this container is the one that needs the reach.
DATA=/data
DOWNLOADS="$DATA/downloads"
QUARANTINE="$DOWNLOADS/.quarantine"
AUDIOBOOKS="$DOWNLOADS/audiobooks"
# Where a clean audiobook lands: the books stack's drop directory, bind
# mounted here (and read-only into audiobookshelf, which has it as a folder
# of its Audiobooks library). This is the ONLY thing the two stacks share —
# no network path, no download tree mounted into the books stack.
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
  qdest="$QUARANTINE/$(basename "$qf").$(date +%s)"
  if ! mv -f "$qf" "$qdest"; then
    echo "scan: ERROR: could not quarantine $qf" >&2
    return 1
  fi
  echo "scan: INFECTED $qf -> $qdest"

  # Nothing else can point at it when the moved file is the only link — the
  # overwhelmingly common case, and worth not walking the tree for.
  qlinks=$(stat -c %h "$qdest" 2>/dev/null || echo 1)
  if [ "$qlinks" -gt 1 ] 2>/dev/null; then
    qino=$(stat -c %i "$qdest" 2>/dev/null || echo "")
    if [ -n "$qino" ]; then
      # -xdev: hardlinks cannot cross a filesystem, so nothing outside this
      # one can share the inode. The quarantined copy is excluded by the
      # -path prune, which is what makes it the surviving evidence link.
      find "$DATA" -xdev -path "$QUARANTINE" -prune -o \
        -type f -inum "$qino" -print 2>/dev/null | while IFS= read -r ql; do
        if rm -f "$ql"; then
          echo "scan: UNLINKED $ql (hardlink to quarantined inode $qino)"
          notify "ClamAV unlinked a hardlink to a quarantined file: $ql"
        else
          echo "scan: ERROR: could not unlink $ql (inode $qino) — INFECTED CONTENT IS STILL REACHABLE THERE" >&2
        fi
      done
    else
      echo "scan: ERROR: could not stat $qdest for its inode — other hardlinks (if any) NOT purged" >&2
    fi
  fi
  notify "ClamAV quarantined: $qf"
  return 0
}

# ---------------------------------------------------------------------------
# Audiobook promotion (Option C — ServerNotes/designs/audiobook-acquisition.md)
# ---------------------------------------------------------------------------
# The `audiobooks` qBittorrent category is the one thing here that is NOT
# imported by an *arr, so this loop is also its importer. Rules:
#   - WHOLE ENTRIES, not files: an audiobook torrent is a folder of tracks
#     and it has ONE verdict. downloads/audiobooks is therefore pruned from
#     the per-file pass above; if it were not, a per-file quarantine could
#     strip the infected track and leave the rest looking clean enough to
#     promote.
#   - The move happens ONLY after a clean verdict on every file in the entry.
#     That is the same clamdscan verdict the quarantine path uses — the
#     ordering is not "arranged", it is that the mover IS the scan loop.
#   - Two-pass size stability before scanning: qBittorrent writes completed
#     files into the category directory, and scanning a half-written entry
#     would either waste a pass or promote a partial book. `du -s` compared
#     with the previous pass is portable (busybox) and needs no clock
#     arithmetic.
#   - Cost, accepted with the decision: the entry LEAVES the download tree,
#     so qBittorrent stops seeding it. Audiobooks are not hardlink-imported
#     by anything, so there is no library link to keep alive.
promote_audiobooks() {
  [ -d "$AUDIOBOOKS" ] || return 0
  if [ ! -d "$DROP" ]; then
    echo "scan: WARN: drop dir $DROP is missing — audiobook promotion skipped" >&2
    return 0
  fi
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
    # A pipeline's `while` runs in a subshell, so the verdict travels through
    # a file rather than a variable.
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
      # Condemn the whole entry: its infected files are already quarantined
      # inode-effectively above; what is left of it must not look promotable
      # on the next pass.
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
      # Same filesystem (/mnt/slow) => a rename, so the entry appears in the
      # drop dir complete or not at all. Ownership rides along with the
      # inode (1000:1000, qBittorrent's PUID), which is what the books stack
      # reads it as.
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
  # Timestamp BEFORE scanning, so files modified mid-pass are re-scanned next
  # pass instead of slipping through the window.
  touch /tmp/scan-pass

  # A marker with a mtime in the FUTURE — a clock step, a restored /state, a
  # copy that landed the timestamp wrong — makes `-newer` exclude every file
  # forever, and the loop goes on running and scanning nothing. That failure
  # is completely silent, which is the worst property a scanner can have.
  # Notice it and start over.
  # (`find -newer` rather than `test -nt`: -nt is not POSIX test.)
  if [ -f "$MARKER" ] && [ -n "$(find "$MARKER" -newer /tmp/scan-pass)" ]; then
    echo "scan: WARN: $MARKER is dated in the future (clock step?) — discarding it and rescanning everything" >&2
    rm -f "$MARKER"
  fi

  # downloads/audiobooks is pruned here and handled entry-at-a-time by
  # promote_audiobooks (see its header).
  #
  # Collected into a variable rather than piped straight into the loop: a
  # pipeline's `while` is a subshell, and this way the pass can also SAY how
  # many candidates it found. That line is not decoration — a scanner that
  # finds nothing and a scanner whose loop has died look identical in the
  # logs otherwise, and telling them apart cost most of a suite cycle once.
  # It only prints when there is something to scan, so a quiet tree stays
  # quiet.
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
        # 2 = scan error (unreadable, clamd hiccup): log and keep going; the
        # file stays eligible next pass because the marker only advances below.
        echo "scan: ERROR: clamdscan rc=$rc on $f" >&2
      fi
    done
  fi

  promote_audiobooks

  mv /tmp/scan-pass "$MARKER"
  sleep "$INTERVAL"
done
