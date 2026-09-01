#!/bin/bash
#
# Deploys NixOS to a Hetzner VPS using nixos-anywhere.
# The AGE key is injected via --extra-files so sops-nix can decrypt secrets at boot.
#
# Prerequisites:
#   1. Create Hetzner Cloud VPS (Ubuntu 22.04, add your SSH key)
#   2. Note the public IP address
#   3. Ensure sops_age_key.txt exists in parent directory
#
# Usage: ./deploy.sh <VPS_IP>
#
# Example:
#   ./deploy.sh 65.108.xx.xx

set -euo pipefail

cd "$(dirname "$0")"

VPS_IP="${1:?Usage: $0 <VPS_IP>}"
AGE_KEY_FILE="../sops_age_key.txt"
EXTRA_FILES_DIR=$(mktemp -d)
trap "rm -rf $EXTRA_FILES_DIR" EXIT

echo "=== Headscale VPS Deployment ==="
echo ""

# The canonical copy of the key is root-only at /var/lib/sops-nix (the
# sopsedit convention: it never moves into the workspace, each use costs a
# sudo). A workspace-level ../sops_age_key.txt still wins if present, for
# running this from a machine that is not the desktop. The temp copy lives
# OUTSIDE $EXTRA_FILES_DIR on purpose — that whole directory ships to the
# VPS filesystem root via --extra-files.
if [[ ! -f "$AGE_KEY_FILE" && -e /var/lib/sops-nix/sops_age_key.txt ]]; then
    echo "> No workspace key; reading /var/lib/sops-nix (sudo)"
    AGE_KEY_TMP=$(mktemp)
    trap "rm -rf $EXTRA_FILES_DIR; rm -f $AGE_KEY_TMP" EXIT
    sudo cat /var/lib/sops-nix/sops_age_key.txt > "$AGE_KEY_TMP"
    chmod 600 "$AGE_KEY_TMP"
    AGE_KEY_FILE="$AGE_KEY_TMP"
fi

# Check age key exists
if [[ ! -f "$AGE_KEY_FILE" ]]; then
    echo "Error: AGE key not found at ../sops_age_key.txt or /var/lib/sops-nix/"
    echo ""
    echo "To generate a new key:"
    echo "  age-keygen -o ../sops_age_key.txt"
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
cp "$AGE_KEY_FILE" "$EXTRA_FILES_DIR/var/lib/sops-nix/sops_age_key.txt"
chmod 700 "$EXTRA_FILES_DIR/var/lib/sops-nix"
chmod 600 "$EXTRA_FILES_DIR/var/lib/sops-nix/sops_age_key.txt"

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

# Run nixos-anywhere. Pinned to a release tag: this tool runs locally with
# the age master key staged in $EXTRA_FILES_DIR and as root on the target,
# so a floating ref would hand upstream's default branch both. Every image
# in the fleet is pinned for the same reason. Bump deliberately.
nix run github:nix-community/nixos-anywhere/1.13.0 -- \
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
echo "  sudo ls -la /var/lib/sops-nix/sops_age_key.txt"
echo ""
echo "Check services:"
echo "  sudo systemctl status headscale"
echo "  sudo systemctl status authentik"
echo "  sudo journalctl -u headscale -f"
echo ""
echo "For config-only updates (no reinstall):"
echo "  nixos-rebuild switch --target-host idan@$VPS_IP --use-remote-sudo --flake .#headscale-vps"
echo ""
