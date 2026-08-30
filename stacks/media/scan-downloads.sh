#!/bin/sh
# scan-downloads.sh — ClamAV poll-watcher for the downloads tree (annex §5).
#
# Runs in a second container from the SAME pinned clamav/clamav image (so
# clamdscan is present without any apk at boot — finding #4), talking to clamd
# in the `clamav` service over TCP. Both containers mount the downloads tree
# at the same path, so path-based scan requests resolve on clamd's side.
#
# Behaviour:
#   - every $SCAN_INTERVAL_SECONDS: scan files modified since the last pass
#     (first pass scans everything);
#   - infected  -> mv into /data/downloads/.quarantine/ + ntfy POST. The arr
#     import then fails and Cleanuparr's strike system removes + blocklists
#     the release — the ClamAV->Cleanuparr interplay is deliberately indirect;
#   - clean     -> untouched (the media suite asserts both directions, EICAR
#     as the trigger).
#
# Poll (find -newer) rather than inotify on purpose: simplest, test-friendly,
# and immune to watch-descriptor exhaustion on big trees. Filenames with
# newlines are not handled (find|read line protocol) — torrents do not
# produce them in practice.
set -u

DOWNLOADS=/data/downloads
QUARANTINE="$DOWNLOADS/.quarantine"
MARKER=/state/last-scan
CONF=/tmp/clamd-client.conf
NTFY_URL="${NTFY_URL:-http://ntfy/media}"
INTERVAL="${SCAN_INTERVAL_SECONDS:-60}"

mkdir -p "$QUARANTINE" /state
printf 'TCPSocket 3310\nTCPAddr clamav\n' > "$CONF"

echo "scan: waiting for clamd at clamav:3310"
until clamdscan --config-file="$CONF" --ping 1 >/dev/null 2>&1; do
  sleep 5
done
echo "scan: clamd up; polling $DOWNLOADS every ${INTERVAL}s"

while :; do
  # Timestamp BEFORE scanning, so files modified mid-pass are re-scanned next
  # pass instead of slipping through the window.
  touch /tmp/scan-pass

  if [ -f "$MARKER" ]; then
    find "$DOWNLOADS" -path "$QUARANTINE" -prune -o -type f -newer "$MARKER" -print
  else
    find "$DOWNLOADS" -path "$QUARANTINE" -prune -o -type f -print
  fi | while IFS= read -r f; do
    clamdscan --config-file="$CONF" --no-summary "$f" >/dev/null 2>&1
    rc=$?
    if [ "$rc" = 1 ]; then
      dest="$QUARANTINE/$(basename "$f").$(date +%s)"
      if mv -f "$f" "$dest"; then
        echo "scan: INFECTED $f -> $dest"
        # busybox wget; failure to notify must not stop quarantining.
        wget -q -O /dev/null --post-data "ClamAV quarantined: $f" "$NTFY_URL" \
          || echo "scan: WARN: ntfy notification failed for $f" >&2
      else
        echo "scan: ERROR: could not quarantine $f" >&2
      fi
    elif [ "$rc" != 0 ]; then
      # 2 = scan error (unreadable, clamd hiccup): log and keep going; the
      # file stays eligible next pass because the marker only advances below.
      echo "scan: ERROR: clamdscan rc=$rc on $f" >&2
    fi
  done

  mv /tmp/scan-pass "$MARKER"
  sleep "$INTERVAL"
done
