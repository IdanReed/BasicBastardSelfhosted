#!/usr/bin/env bash
# infect.sh — convert the fresh Vultr Ubuntu box to NixOS, carrying scanner.nix.
#
# Run from the operator workstation. DESTRUCTIVE: nixos-infect reimages the OS
# in place and reboots. The box is a throwaway — if it bricks, destroy and
# recreate the Vultr instance (pennies) and rerun this.
#
#   ./infect.sh [IP]            # default IP below
#   SCANNER_SSH_KEY=~/.ssh/foo ./infect.sh 203.0.113.9
set -euo pipefail

IP="${1:-149.28.124.97}"
KEY="${SCANNER_SSH_KEY:-$HOME/.ssh/vultr_scanner}"
CHANNEL="${NIX_CHANNEL:-nixos-26.05}"
here="$(cd "$(dirname "$0")" && pwd)"
SSH=(ssh -i "$KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
SCP=(scp -i "$KEY" -o StrictHostKeyChecking=accept-new)

echo ">> target root@$IP  (key: $KEY, channel: $CHANNEL)"
"${SSH[@]}" root@"$IP" '. /etc/os-release 2>/dev/null; echo "current OS: ${PRETTY_NAME:-unknown}"'

echo ">> staging scanner.nix -> /etc/nixos/scanner.nix"
"${SSH[@]}" root@"$IP" 'mkdir -p /etc/nixos'
"${SCP[@]}" "$here/scanner.nix" root@"$IP":/etc/nixos/scanner.nix

echo ">> running nixos-infect (reimages + reboots; ssh WILL drop at the end)"
# NO_SWAP=true: the box already has swap, and infect only auto-detects a BLOCK
# device — with a /swapfile it would dd a new 1G file into the tmpfs /tmp and
# fail "No space left on device". We keep the existing swap instead.
"${SSH[@]}" root@"$IP" "
  rm -f /tmp/nixos-infect.*.swp
  # Small Vultr boxes mount /tmp as a ~475M tmpfs; the nix build can want more.
  # Grow it (backed by the existing swap) so realisation does not run out.
  mount -o remount,size=2G /tmp 2>/dev/null || true
  curl -fsSL https://raw.githubusercontent.com/elitak/nixos-infect/master/nixos-infect \
  | PROVIDER=vultr NIX_CHANNEL=$CHANNEL NIXOS_IMPORT=./scanner.nix NO_SWAP=true bash -x
" || echo ">> ssh dropped (expected when the box reboots into NixOS)"

echo ">> forgetting the old (Ubuntu) host key; NixOS regenerates its own"
ssh-keygen -R "$IP" >/dev/null 2>&1 || true

echo ">> waiting for NixOS to come back (up to ~10 min)..."
for i in $(seq 1 60); do
  sleep 10
  if ver=$("${SSH[@]}" -o BatchMode=yes root@"$IP" 'test -e /etc/NIXOS && nixos-version' 2>/dev/null); then
    echo ">> NixOS is up: $ver"
    echo ">> next: ./provision.sh $IP"
    exit 0
  fi
  echo "   ...still waiting ($i/60)"
done
echo "!! timed out; check the Vultr console for the box" >&2
exit 1
