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

# 0600 from birth: config.json carries RESTIC_PASSWORD and the admin bcrypt
# hash, and with the default umask 022 the rendered file would sit
# world-readable between the write and the chmod below. With 077 every file
# created here is 0600 from the start.
umask 077

# Fail loudly BEFORE Backrest starts if the storage box key is absent OR
# still the sops changeme_ placeholder — the placeholder is the DEFAULT
# state of a fresh deploy (sops-nix + the tmpfiles C+ rule always
# materialise a non-empty file), so an empty-only check would let Backrest
# start doomed to crash-loop on ssh auth with no alert.
#
# `! -f` before `! -s` is NOT redundant: the key is mounted as a SINGLE
# FILE, and a missing host path makes docker manufacture a DIRECTORY at it
# (verified — same behaviour the compose header documents for /config),
# which passes `-s` (4096 bytes) while grep exits non-zero — an `-s`-only
# gate waves the empty case through. Self-healing: the tmpfiles `C+` rule
# removes whatever is at the path before re-copying on the next boot or
# switch.
if [ ! -f /keys/storagebox_ed25519 ] || [ ! -s /keys/storagebox_ed25519 ] \
   || grep -q '^changeme_' /keys/storagebox_ed25519; then
  echo "ERROR: /var/lib/backup/storagebox_ed25519 is missing or still the changeme_ placeholder."
  echo "  The key is sops-managed: put the real private key in"
  echo "  BACKUP_STORAGEBOX_SSH_KEY via: sops nixos/secrets.sops.yaml"
  echo "  (see stacks/backrest/README.md section 2 and CLAUDE.md 'SSH identities')"
  exit 1
fi

# Same class of gate as the key check above, for the OTHER half of the
# storage-box identity: ssh_config is committed with a uXXXXXX username
# placeholder, and nothing else validates it — the key can be real while the
# hostname it dials is literally uXXXXXX.your-storagebox.de. That failure is
# DNS at backup time, hours after deploy, with Backrest already green.
if [ ! -f /template/ssh_config ] || grep -q '^[^#]*uXXXXXX' /template/ssh_config; then
  echo "ERROR: stacks/backrest/ssh_config is missing or still carries the uXXXXXX placeholder."
  echo "  Fill in the real Storage Box username (u******) in ssh_config —"
  echo "  see stacks/backrest/README.md section 2."
  exit 1
fi

if [ -f /config/config.json ]; then
  echo "config.json already exists - leaving it alone"
  exit 0
fi

# Substitution is busybox awk over ENVIRON, not envsubst: `apk add gettext`
# put the registry in the boot path (unreachable at boot -> whole backup
# stack down) and made the stack untestable in the offline VM suite.
# Everything used below ships in alpine:3.21. Unlike envsubst, an unset or
# empty variable is a hard error, not a silent "".
#
# A `changeme` placeholder is treated exactly like empty: it is the DEFAULT
# state of a fresh deploy, and config.json is seeded EXACTLY ONCE — a
# placeholder baked in is permanent and nothing downstream ever complains.
# Per variable:
#   RESTIC_PASSWORD                 placeholder is a PUBLIC string in this
#                                   repo — it would encrypt a real repository
#                                   holding every backup.
#   BACKREST_ADMIN_PASSWORD_BCRYPT  placeholder is not a valid bcrypt hash;
#                                   nobody could ever log in.
#   DEADMAN_URL                     placeholder 404s, and actionHealthchecks
#                                   is ON_ERROR_IGNORE — yet this is the ONLY
#                                   external signal in the fleet, the one
#                                   thing that catches "the timer stopped
#                                   firing three weeks ago". A dead-man that
#                                   never pings reads as configured: worse
#                                   than none.
#
# Substring match, not a `changeme_` prefix: DEADMAN_URL's placeholder
# carries it in the path (changeme-uuid), not at the start.
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
    # Values go into JSON verbatim (the awk below does no escaping): a double
    # quote breaks the parse, and a backslash parses as a JSON escape — restic
    # would then encrypt the repo with a password DIFFERENT from the
    # sops-recorded value, found only at disaster recovery. Same gate
    # immich-config-init carries for exactly this class.
    *'"'*|*'\'*)
      echo "ERROR: $v contains a double quote or backslash - inserted verbatim"
      echo "  into JSON it would corrupt config.json (or silently change the"
      echo "  value restic actually uses). Pick a value without either"
      echo "  character in stacks/backrest/.sops.env."
      fail=1
      ;;
  esac
done
[ "$fail" -eq 0 ]

# Left-to-right single pass, no rescan of substituted output — a value that
# itself contains '${' is inserted literally, matching envsubst.
#
# Rendered to a tmpfile and renamed into place: the seed-once guard up top
# trusts any existing config.json forever, so a crash mid-write (ENOSPC,
# OOM-kill) landing directly on the final path would leave truncated JSON
# that `-f` then protects until a human deletes it. The chmod is a no-op
# under the umask above, kept because the 0600 contract (asserted by the
# suite) deserves to be visible where the file is made.
awk '{
  out = ""
  rest = $0
  while (match(rest, /\$\{[A-Za-z_][A-Za-z0-9_]*\}/)) {
    v = substr(rest, RSTART + 2, RLENGTH - 3)
    out = out substr(rest, 1, RSTART - 1) ENVIRON[v]
    rest = substr(rest, RSTART + RLENGTH)
  }
  print out rest
}' /template/config.template.json > /config/.config.json.tmp
chmod 600 /config/.config.json.tmp
mv /config/.config.json.tmp /config/config.json
echo "seeded config.json"
