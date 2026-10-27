#!/usr/bin/env bash
# provision.sh — second leg: clone the public repo onto the (now NixOS) scanner,
# deliver the private targets file, and verify the toolkit. Run after infect.sh.
#
#   ./provision.sh [IP]
#
# Targets: the private target list lives age-encrypted in ServerNotes and is
# decrypted HERE (one sudo, like every other secret) and pushed to the box —
# it never lands in this public-mirrored repo. Override the source path with
# SCANNER_TARGETS_SOPS, or skip delivery with SKIP_TARGETS=1.
set -euo pipefail

IP="${1:-149.28.124.97}"
KEY="${SCANNER_SSH_KEY:-$HOME/.ssh/vultr_scanner}"
REPO="${SCANNER_REPO:-https://github.com/IdanReed/BasicBastardSelfhosted.git}"
here="$(cd "$(dirname "$0")" && pwd)"
TARGETS_SOPS="${SCANNER_TARGETS_SOPS:-$here/../../ServerNotes/secrets/scanner-targets.sops.env}"
AGE_KEY="${SOPS_AGE_KEY_FILE:-/var/lib/sops-nix/sops_age_key.txt}"
SSH=(ssh -i "$KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
SCP=(scp -i "$KEY" -o StrictHostKeyChecking=accept-new)

echo ">> clone the public repo on the box (as user idan)"
"${SSH[@]}" idan@"$IP" "
  set -e
  # Full history, not shallow: Phase 1 runs gitleaks over --log-opts=--all.
  test -d ~/BasicBastardSelfhosted/.git || git clone '$REPO' ~/BasicBastardSelfhosted
  git -C ~/BasicBastardSelfhosted pull --ff-only || true
  echo 'repo at:' ~/BasicBastardSelfhosted
"

if [ "${SKIP_TARGETS:-0}" != "1" ]; then
  echo ">> decrypt private targets and push to the box (plaintext only on the box + a tmpfile)"
  tmp="$(mktemp)"; trap 'shred -u "$tmp" 2>/dev/null || rm -f "$tmp"' EXIT
  sudo env SOPS_AGE_KEY="$(sudo cat "$AGE_KEY")" \
    sops -d --input-type dotenv --output-type dotenv "$TARGETS_SOPS" > "$tmp"
  "${SCP[@]}" "$tmp" idan@"$IP":/home/idan/targets.env
  "${SSH[@]}" idan@"$IP" 'chmod 600 ~/targets.env; echo "targets at ~/targets.env (source it: set -a; . ~/targets.env; set +a)"'
else
  echo ">> SKIP_TARGETS=1 — not delivering targets.env"
fi

# The scanner brief (the goal doc) lives in the private ServerNotes repo, so it
# does NOT come down with the public-repo clone. Deliver it into ~/scan/ where
# the on-box agent reads it. Not a secret beyond the private IPs it names, which
# the box already holds via targets.env.
BRIEF_SRC="${SCANNER_BRIEF:-$here/../../ServerNotes/designs/security-external-testing.md}"
if [ "${SKIP_BRIEF:-0}" != "1" ] && [ -f "$BRIEF_SRC" ]; then
  echo ">> deliver the scanner brief -> ~/scan/brief.md"
  "${SSH[@]}" idan@"$IP" 'mkdir -p ~/scan && ln -sf ~/targets.env ~/scan/targets.env'
  "${SCP[@]}" "$BRIEF_SRC" idan@"$IP":/home/idan/scan/brief.md
else
  echo ">> SKIP_BRIEF or brief not found ($BRIEF_SRC) — not delivering brief"
fi

echo ">> verify the toolkit is on PATH"
"${SSH[@]}" idan@"$IP" '
  for t in nmap testssl.sh nuclei subfinder dnsx gitleaks ssh-audit dig whois openssl curl jq git tailscale claude; do
    if command -v "$t" >/dev/null; then printf "  ok   %s\n" "$t"; else printf "  MISS %s\n" "$t"; fi
  done
  echo; echo "ipv6 egress:"; curl -6 -s --max-time 8 https://ifconfig.co || echo "  (none)"
'

cat <<EOF

>> provisioned. The goal doc is at ~/scan/brief.md on the box. To start:
   ssh -i $KEY idan@$IP
   cd ~/scan
   set -a; . ./targets.env; set +a     # export VPS_IP, HOME_IP, ...
   claude                               # auth on first run, then: "read brief.md and run Phase 1"

   Manual bits (no credentials are baked into the image):
   1. Claude auth: 'claude' login, or export ANTHROPIC_API_KEY.
   2. Re-verify the dynamic targets (home WAN v4 / v6 prefix) before a run — they are
      ISP-assigned. See brief.md Setup 4.
   3. Keep the box OFF the tailnet for phases 1-4. Phase 5 only: sudo tailscale up.
EOF
