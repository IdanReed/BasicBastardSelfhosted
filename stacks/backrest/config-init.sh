#!/bin/sh
# Seeds config.json ONCE from config.template.json. Backrest owns the file
# afterwards, so this must never overwrite it — the template is a bootstrap
# seed, not a source of truth. To re-seed: delete
# /mnt/fast/backrest/config/config.json.
#
# This lives in a file (mounted read-only next to the template) rather than
# inline in compose.yaml because it is full of `$`, and compose interpolates
# every `$` in the YAML unless doubled — a standing trap for future edits.
set -eu

# Fail loudly BEFORE Backrest starts if the storage box key is absent.
# depends_on: service_completed_successfully means Backrest will not come up
# in a state where every backup fails on ssh auth.
if [ ! -s /keys/storagebox_ed25519 ]; then
  echo "ERROR: /var/lib/backup/storagebox_ed25519 missing or empty on the host."
  echo "  ssh-keygen -t ed25519 -N '' -f /var/lib/backup/storagebox_ed25519"
  echo "  ssh-copy-id -p 23 -i /var/lib/backup/storagebox_ed25519.pub uXXXXXX@uXXXXXX.your-storagebox.de"
  exit 1
fi

if [ -f /config/config.json ]; then
  echo "config.json already exists - leaving it alone"
  exit 0
fi

# Substitution is busybox awk over ENVIRON, not envsubst: `apk add gettext`
# put the network in the boot path (registry unreachable at boot -> the whole
# backup stack down) and made the stack untestable in the offline VM suite.
# Everything used below ships in alpine:3.21.
#
# Unlike bare envsubst, an unset or empty variable is a hard error, not a
# silent "": an empty restic password or webhook URL in a freshly seeded
# config is exactly the quiet breakage this container exists to prevent.
fail=0
for v in $(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' /template/config.template.json | tr -d '${}' | sort -u); do
  eval "val=\${$v:-}"
  if [ -z "$val" ]; then
    echo "ERROR: $v is unset or empty in .env - refusing to seed config.json"
    fail=1
  fi
done
[ "$fail" -eq 0 ]

# Left-to-right single pass, no rescan of substituted output — a value that
# itself contains '${' is inserted literally, matching envsubst.
awk '{
  out = ""
  rest = $0
  while (match(rest, /\$\{[A-Za-z_][A-Za-z0-9_]*\}/)) {
    v = substr(rest, RSTART + 2, RLENGTH - 3)
    out = out substr(rest, 1, RSTART - 1) ENVIRON[v]
    rest = substr(rest, RSTART + RLENGTH)
  }
  print out rest
}' /template/config.template.json > /config/config.json
chmod 600 /config/config.json
echo "seeded config.json"
