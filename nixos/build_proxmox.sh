#!/bin/bash
#
# Configures cloud-init with the age key and starts the VM.
# The age key is injected so sops-nix can decrypt secrets at boot.
#
# Usage: ./build_proxmox.sh VM_ID

set -euo pipefail

cd "$(dirname "$0")"

VM_ID="${1:?Usage: $0 VM_ID}"
VM_IP="10.0.0.3"
AGE_KEY_FILE="../age-key.txt"
SNIPPETS_DIR="/var/lib/vz/snippets"

# Check age key exists
if [[ ! -f "$AGE_KEY_FILE" ]]; then
    echo "> Error: Age key not found at $AGE_KEY_FILE"
    echo "> This file should contain your age private key (starts with AGE-SECRET-KEY-)"
    exit 1
fi

AGE_KEY=$(cat "$AGE_KEY_FILE")

echo "> Stopping VM $VM_ID if running..."
qm stop "$VM_ID" 2>/dev/null || true

echo "> Generating cloud-init userdata..."

# Create cloud-init config that writes the age key
cat > "$SNIPPETS_DIR/nixos-userdata.yaml" << EOF
#cloud-config
write_files:
  - path: /var/lib/sops-nix/key.txt
    permissions: '0600'
    owner: root:root
    content: |
      ${AGE_KEY}

runcmd:
  - mkdir -p /var/lib/sops-nix
  - chmod 700 /var/lib/sops-nix
EOF

echo "> Configuring VM $VM_ID..."
qm set "$VM_ID" --cicustom "user=local:snippets/nixos-userdata.yaml"
qm set "$VM_ID" --ipconfig0 "ip=$VM_IP/24,gw=10.0.0.1"
qm set "$VM_ID" --nameserver "10.0.0.1"

echo "> Regenerating Cloud-Init image..."
qm cloudinit update "$VM_ID"

echo "> Starting VM $VM_ID..."
qm start "$VM_ID"

echo "> Done."
echo ""
echo "VM should be accessible shortly at:"
echo "  ssh idan@$VM_IP"
echo ""
echo "For config-only updates (no re-image), run from your desktop:"
echo "  nixos-rebuild switch --target-host idan@$VM_IP --use-remote-sudo --flake .#services-vm"
