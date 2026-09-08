#!/bin/sh
# Seeds config.json ONCE from config.template.json. Backrest owns the file
# afterwards, so this must never overwrite it — the template is a bootstrap
# seed, not a source of truth. To re-seed, delete
# /mnt/fast/backrest/config/config.json.
#
# A file rather than inline in compose.yaml because it is full of `$`, which
# compose interpolates unless doubled.
set -eu

# 0600 from birth: config.json carries RESTIC_PASSWORD and the admin bcrypt
# hash, and the default umask would leave it world-readable until the chmod.
umask 077

# Refuse to start if the storage-box key is absent or still the changeme_
# placeholder — the placeholder is the DEFAULT state of a fresh deploy, so an
# empty-only check would let Backrest crash-loop on ssh auth with no alert.
#
# `! -f` before `! -s` is NOT redundant: a missing host path for a single-file
# bind makes docker manufacture a DIRECTORY, which passes `-s`.
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

# busybox awk over ENVIRON, not envsubst: `apk add gettext` would put the
# registry in the boot path and break the offline suite, and unlike envsubst
# an unset or empty variable is a hard error rather than a silent "".
#
# A `changeme` placeholder counts as empty: config.json is seeded EXACTLY
# ONCE, so one baked in is permanent and nothing downstream complains.
# Substring match, not a prefix — DEADMAN_URL carries it mid-path.
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
    # Values go into JSON verbatim: a quote breaks the parse and a backslash
    # parses as an escape, so restic would encrypt the repo with a password
    # different from the sops-recorded one — found only at recovery time.
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

# Left-to-right single pass, no rescan of substituted output.
#
# Tmpfile + rename: the seed-once guard trusts any existing config.json
# forever, so a crash mid-write landing on the final path would leave
# truncated JSON that `-f` then protects until a human deletes it.
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
