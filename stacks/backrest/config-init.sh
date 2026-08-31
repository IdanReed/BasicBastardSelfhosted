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

# Fail loudly BEFORE Backrest starts if the storage box key is absent OR
# still the sops changeme_ placeholder — the placeholder is the DEFAULT state
# of a fresh deploy (sops-nix + the tmpfiles C+ rule always materialise a
# non-empty file from the committed template), so an empty-only check would
# let Backrest start doomed and crash-loop on ssh auth with no alert.
# depends_on: service_completed_successfully means Backrest will not come up
# in a state where every backup fails on ssh auth.
#
# `! -f` before `! -s`, and it is not redundant: compose mounts the key as a
# SINGLE FILE now, and when the host path is missing docker manufactures a
# DIRECTORY at it (verified — the same behaviour the compose header documents
# for /config). A directory passes `-s` (it is 4096 bytes) and makes grep exit
# non-zero, so an `-s`-only gate would wave the empty case straight through.
# The manufactured directory is not permanent: the tmpfiles `C+` rule removes
# whatever is at that path before copying, so the next boot or `nixos-rebuild
# switch` repairs it.
if [ ! -f /keys/storagebox_ed25519 ] || [ ! -s /keys/storagebox_ed25519 ] \
   || grep -q '^changeme_' /keys/storagebox_ed25519; then
  echo "ERROR: /var/lib/backup/storagebox_ed25519 is missing or still the changeme_ placeholder."
  echo "  The key is sops-managed: put the real private key in"
  echo "  BACKUP_STORAGEBOX_SSH_KEY via: sops nixos/secrets.sops.yaml"
  echo "  (see stacks/backrest/README.md section 2 and CLAUDE.md 'SSH identities')"
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
#
# A `changeme` placeholder is treated exactly like empty, for the same reason
# the storage-box key gate above rejects it: the placeholder is the DEFAULT
# state of a fresh deploy, and config.json is seeded EXACTLY ONCE — after that
# Backrest owns the file, so a placeholder baked in here is a placeholder
# forever, and nothing downstream ever complains. Concretely, for each of the
# three variables in the template today:
#
#   RESTIC_PASSWORD                 the placeholder is a PUBLIC string in this
#                                   repository, and it would encrypt a real
#                                   repository containing every backup.
#   BACKREST_ADMIN_PASSWORD_BCRYPT  the placeholder is not valid base64 of a
#                                   bcrypt hash, so nobody could ever log in.
#   DEADMAN_URL                     the placeholder is
#                                   https://hc-ping.com/changeme-uuid, which
#                                   404s. actionHealthchecks hooks are
#                                   ON_ERROR_IGNORE, so a 404 is logged and
#                                   dropped — and this is the ONLY external
#                                   signal in the fleet, the one thing that
#                                   catches "the timer stopped firing three
#                                   weeks ago". A dead-man that never pings
#                                   anything real is worse than none: it reads
#                                   as configured.
#
# Substring match, not a `changeme_` prefix: DEADMAN_URL's placeholder carries
# it in the path (changeme-uuid), not at the start.
fail=0
for v in $(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' /template/config.template.json | tr -d '${}' | sort -u); do
  eval "val=\${$v:-}"
  if [ -z "$val" ]; then
    echo "ERROR: $v is unset or empty in .env - refusing to seed config.json"
    fail=1
    continue
  fi
  case "$val" in
    *changeme*|*CHANGEME*)
      echo "ERROR: $v is still a changeme placeholder from .sops.env.example"
      echo "  - refusing to seed config.json. config.json is written ONCE;"
      echo "  Backrest owns it afterwards, so a placeholder seeded now is"
      echo "  permanent. Put the real value in stacks/backrest/.sops.env"
      echo "  (see .sops.env.example for how to generate each one)."
      fail=1
      ;;
  esac
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
