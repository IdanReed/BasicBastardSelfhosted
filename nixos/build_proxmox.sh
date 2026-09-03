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
AGE_KEY_FILE="../sops_age_key.txt"
SNIPPETS_DIR="/var/lib/vz/snippets"

# Check age key exists
if [[ ! -f "$AGE_KEY_FILE" ]]; then
    echo "> Error: Age key not found at $AGE_KEY_FILE"
    echo "> This file should contain your age private key (starts with AGE-SECRET-KEY-)"
    exit 1
fi

# Indent EVERY line to match the block scalar below: age-keygen output is
# three lines, and interpolating it raw leaves lines 2-3 at column 0 —
# terminating the scalar, invalidating the YAML, and silently leaving the key
# unwritten on every re-image.
AGE_KEY_INDENTED=$(sed 's/^/      /' "$AGE_KEY_FILE")

echo "> Stopping VM $VM_ID if running..."
qm stop "$VM_ID" 2>/dev/null || true

echo "> Generating cloud-init userdata..."

# Create cloud-init config that writes the age key
cat > "$SNIPPETS_DIR/nixos-userdata.yaml" << EOF
#cloud-config
write_files:
  - path: /var/lib/sops-nix/sops_age_key.txt
    permissions: '0600'
    owner: root:root
    content: |
${AGE_KEY_INDENTED}

runcmd:
  - mkdir -p /var/lib/sops-nix
  - chmod 700 /var/lib/sops-nix
EOF

# Fail here rather than after a boot into a host that cannot decrypt its own
# secrets. Skipped if the Proxmox host has no python3/pyyaml.
if python3 -c 'import yaml' 2>/dev/null; then
    if python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' \
            "$SNIPPETS_DIR/nixos-userdata.yaml"; then
        echo "> cloud-init userdata validated"
    else
        echo "> Error: generated cloud-init YAML is invalid"
        echo "> Check $SNIPPETS_DIR/nixos-userdata.yaml"
        exit 1
    fi
else
    echo "> Note: python3/pyyaml unavailable, skipping YAML validation"
fi

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
echo "> NOTE: reboot the VM once after this first boot (or run nixos-rebuild"
echo "> switch on it). cloud-init writes the age key AFTER the first sops-nix"
echo "> activation, so /run/secrets stays empty until the second activation —"
echo "> proven by tests/run.sh proxmox-boot."
echo ""
echo "VM should be accessible shortly at:"
echo "  ssh idan@$VM_IP"
echo ""
echo "For config-only updates (no re-image), run from your desktop:"
echo "  nixos-rebuild switch --target-host idan@$VM_IP --use-remote-sudo --flake .#services-vm"
