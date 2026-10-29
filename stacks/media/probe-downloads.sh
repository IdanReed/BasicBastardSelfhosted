#!/bin/sh
# probe-downloads.sh — the decode check for finished downloads. Runs in a
# container from the pinned Jellyfin image, for its ffprobe: a file Jellyfin's
# own ffprobe cannot read is a file Jellyfin cannot play.
#
# Every $PROBE_INTERVAL_SECONDS, each video file under /data/downloads that is
# finished — outside .incomplete (qBittorrent moves a torrent out of it when
# the torrent completes) and untouched for $PROBE_SETTLE_SECONDS — is probed
# once:
#   - ffprobe reads its container and streams with no error, and finds video
#   - a video frame decodes
#   - the largest video file of each download (the feature or the episode, not
#     its sample or extras) runs at least $PROBE_MIN_MOVIE_SECONDS under
#     downloads/movies, $PROBE_MIN_EPISODE_SECONDS anywhere else: a
#     30-second "film" is a sample or a fake
# A file that fails is quarantined exactly as ClamAV's scanner does it, by
# inode (quarantine.sh), and ntfy'd. A probe that could not run (a timeout, a
# file gone mid-pass) is retried next pass. Audiobooks are the scanner's.
#
# What has been probed is remembered by inode, size and mtime in /tmp: a
# restart probes every finished file once more, which is cheap, and a file
# replaced in place is probed again. Filenames containing newlines are not
# handled.
set -u

DATA=/data
DOWNLOADS="$DATA/downloads"
QUARANTINE="$DOWNLOADS/.quarantine"
INCOMPLETE="$DOWNLOADS/.incomplete"
AUDIOBOOKS="$DOWNLOADS/audiobooks"
NTFY_URL="${NTFY_URL:-http://ntfy/media}"
FFPROBE="${FFPROBE:-/usr/lib/jellyfin-ffmpeg/ffprobe}"
INTERVAL="${PROBE_INTERVAL_SECONDS:-60}"
SETTLE="${PROBE_SETTLE_SECONDS:-120}"
MIN_MOVIE="${PROBE_MIN_MOVIE_SECONDS:-600}"
MIN_EPISODE="${PROBE_MIN_EPISODE_SECONDS:-60}"
SEEN=/tmp/probe-seen
HEARTBEAT=/tmp/probe-alive

Q_TAG=probe
Q_WHO=ffprobe
. /scan/quarantine.sh

mkdir -p "$QUARANTINE"
: > "$SEEN"

is_video() {
  case "$(printf '%s' "${1##*.}" | tr '[:upper:]' '[:lower:]')" in
    mkv|mp4|m4v|avi|mov|wmv|ts|m2ts|mts|webm|mpg|mpeg|flv|vob|ogv) return 0 ;;
  esac
  return 1
}

# The download a file belongs to: its first path component under the
# category directory (downloads/<category>/<entry>), or the file itself.
entry_of() {
  rel=${1#"$DOWNLOADS"/}
  cat=${rel%%/*}
  rest=${rel#*/}
  case "$rest" in
    "$rel") printf '%s\n' "$1" ;;                       # directly in downloads/
    */*) printf '%s\n' "$DOWNLOADS/$cat/${rest%%/*}" ;;
    *) printf '%s\n' "$1" ;;                            # directly in a category
  esac
}

largest_video_of() {
  find "$1" -type f -printf '%s %p\n' 2>/dev/null | sort -rn | while IFS= read -r line; do
    p=${line#* }
    if is_video "$p"; then printf '%s\n' "$p"; break; fi
  done
}

# probe FILE -> prints "ok", "error <why>" (retry) or "reject <why>".
probe() {
  f=$1
  err=/tmp/probe.err
  out=$(timeout 300 "$FFPROBE" -v error -show_entries format=duration:stream=codec_type \
    -of default=noprint_wrappers=1 "$f" 2>"$err")
  rc=$?
  [ -e "$f" ] || { echo "error vanished mid-probe"; return; }
  case $rc in
    124) echo "error ffprobe timed out"; return ;;
    126|127) echo "error ffprobe not runnable (rc $rc)"; return ;;
  esac
  if [ "$rc" != 0 ] || [ -s "$err" ]; then
    echo "reject ffprobe cannot read it: $(head -n 1 "$err" | cut -c1-160)"
    return
  fi
  printf '%s\n' "$out" | grep -qx 'codec_type=video' || { echo "reject no video stream"; return; }

  frames=$(timeout 300 "$FFPROBE" -v quiet -select_streams v:0 -read_intervals '%+#5' \
    -show_entries frame=pts_time -of csv=p=0 "$f" | grep -c .)
  [ "${frames:-0}" -gt 0 ] || { echo "reject no video frame decodes"; return; }

  if [ "$(largest_video_of "$(entry_of "$f")")" = "$f" ]; then
    case "${f#"$DOWNLOADS"/}" in
      movies/*) min=$MIN_MOVIE; what="a movie" ;;
      *) min=$MIN_EPISODE; what="an episode" ;;
    esac
    dur=$(printf '%s\n' "$out" | sed -n 's/^duration=\([0-9]*\).*/\1/p' | head -n 1)
    if [ -z "$dur" ]; then
      echo "ok (duration unknown, not judged)"
      return
    fi
    if [ "$dur" -lt "$min" ]; then
      echo "reject runs ${dur}s, under the ${min}s floor for $what"
      return
    fi
  fi
  echo ok
}

echo "probe: polling $DOWNLOADS every ${INTERVAL}s (settle ${SETTLE}s; floors ${MIN_MOVIE}s movie, ${MIN_EPISODE}s episode)"
while :; do
  touch "$HEARTBEAT"
  touch -d "@$(( $(date +%s) - SETTLE ))" /tmp/probe-settled
  : > "$SEEN.next"
  find "$DOWNLOADS" \( -path "$QUARANTINE" -o -path "$INCOMPLETE" -o -path "$AUDIOBOOKS" \) -prune \
    -o -type f ! -newer /tmp/probe-settled -print | while IFS= read -r f; do
    [ -n "$f" ] && is_video "$f" || continue
    key=$(stat -c '%i:%s:%Y' "$f" 2>/dev/null) || continue
    if grep -qxF "$key" "$SEEN"; then
      echo "$key" >> "$SEEN.next"
      continue
    fi
    verdict=$(probe "$f")
    case "$verdict" in
      ok*)
        echo "probe: OK $f${verdict#ok}"
        echo "$key" >> "$SEEN.next"
        ;;
      reject*)
        quarantine_file "$f" REJECTED "${verdict#reject }"
        ;;
      *)
        echo "probe: WARN: $f: ${verdict#error } - retried next pass" >&2
        ;;
    esac
  done
  mv "$SEEN.next" "$SEEN"
  sleep "$INTERVAL"
done
