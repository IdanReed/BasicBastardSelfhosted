#!/bin/bash
#
# Deploys NixOS to a Hetzner VPS using nixos-anywhere.
# The AGE key is injected via --extra-files so sops-nix can decrypt secrets at boot.
#
# Prerequisites:
#   1. Create Hetzner Cloud VPS (Ubuntu 22.04, add your SSH key)
#   2. Note the public IP address
#   3. Ensure age-key.txt exists in parent directory
#
# Usage: ./deploy.sh <VPS_IP>
#
# Example:
#   ./deploy.sh 65.108.xx.xx

set -euo pipefail

cd "$(dirname "$0")"

VPS_IP="${1:?Usage: $0 <VPS_IP>}"
AGE_KEY_FILE="../age-key.txt"
EXTRA_FILES_DIR=$(mktemp -d)
trap "rm -rf $EXTRA_FILES_DIR" EXIT

echo "=== Headscale VPS Deployment ==="
echo ""

# Check age key exists
if [[ ! -f "$AGE_KEY_FILE" ]]; then
    echo "Error: AGE key not found at $AGE_KEY_FILE"
    echo ""
    echo "To generate a new key:"
    echo "  age-keygen -o $AGE_KEY_FILE"
    echo ""
    echo "Then add the PUBLIC key to .sops.yaml"
    exit 1
fi

# Validate age key format
if ! grep -q "^AGE-SECRET-KEY-" "$AGE_KEY_FILE"; then
    echo "Error: $AGE_KEY_FILE doesn't look like an AGE private key"
    echo "It should start with: AGE-SECRET-KEY-"
    exit 1
fi

echo "> AGE key found: $AGE_KEY_FILE"

# Check SSH connectivity
echo "> Testing SSH connection to $VPS_IP..."
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "root@$VPS_IP" "echo ok" &>/dev/null; then
    echo "Error: Cannot SSH to root@$VPS_IP"
    echo ""
    echo "Ensure:"
    echo "  1. VPS is running"
    echo "  2. Your SSH key was added when creating the VPS"
    echo "  3. Firewall allows SSH (port 22)"
    exit 1
fi
echo "> SSH connection OK"

# Create extra-files directory structure
echo "> Preparing AGE key for injection..."
mkdir -p "$EXTRA_FILES_DIR/var/lib/sops-nix"
cp "$AGE_KEY_FILE" "$EXTRA_FILES_DIR/var/lib/sops-nix/key.txt"
chmod 700 "$EXTRA_FILES_DIR/var/lib/sops-nix"
chmod 600 "$EXTRA_FILES_DIR/var/lib/sops-nix/key.txt"

# Check if nix is available
if ! command -v nix &>/dev/null; then
    echo "Error: nix command not found"
    echo "Install Nix: https://nixos.org/download.html"
    exit 1
fi

echo ""
echo "> Starting nixos-anywhere deployment..."
echo "> This will WIPE the VPS and install NixOS!"
echo ""
read -p "Continue? [y/N] " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
fi

# Run nixos-anywhere
nix run github:nix-community/nixos-anywhere -- \
    --flake ".#headscale-vps" \
    --extra-files "$EXTRA_FILES_DIR" \
    "root@$VPS_IP"

echo ""
echo "=== Deployment Complete ==="
echo ""
echo "The VPS is rebooting into NixOS. Wait ~1 minute, then:"
echo ""
echo "  ssh idan@$VPS_IP"
echo ""
echo "Verify AGE key is in place:"
echo "  sudo ls -la /var/lib/sops-nix/key.txt"
echo ""
echo "Check stack-sync status:"
echo "  sudo systemctl status stack-sync"
echo "  sudo journalctl -u stack-sync -f"
echo ""
echo "For config-only updates (no reinstall):"
echo "  nixos-rebuild switch --target-host idan@$VPS_IP --use-remote-sudo --flake .#headscale-vps"
echo ""
