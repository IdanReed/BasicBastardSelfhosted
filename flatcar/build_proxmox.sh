#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")"

VM_ID="${1:?Usage: $0 VM_ID}"
VM_IP="10.0.0.3"
SSH_USER="idan"
ENV_FILE=".env"
SOPS_FILE="flatcar.sops.env"
TEMPLATE_FILE="flatcar.ign.tmpl"
OUTPUT_FILE="flatcar.ign"
SNIPPETS_DIR="/var/lib/vz/snippets"

# Ignition file
if [[ ! -f "$TEMPLATE_FILE" ]]; then
    echo "> Error: Ignition file not found at $TEMPLATE_FILE"
    exit 1
fi

# Reset and stop flatcar
echo "> Resetting Flatcar VM..."
if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$SSH_USER@$VM_IP" "sudo flatcar-reset"; then
    echo "> Flatcar reset successful"
else
    echo "> Warning: Could not SSH to VM (may not be running). Continuing..."
fi

echo "> Stopping VM $VM_ID..."
qm stop "$VM_ID" 2>/dev/null || true

# Make sure decrypted env files is always deleted
trap 'rm -f "$ENV_FILE"' EXIT

# Env
echo "> Decrypting secrets..."
sops -d "$SOPS_FILE" > "$ENV_FILE"

echo "> Loading environment..."
set -a
source "$ENV_FILE"
set +a

# Sub into ign file
echo "> Substituting variables..."
envsubst '${SSH_AUTHORIZED_KEY} ${TAILSCALE_AUTH_KEY} ${ARCANE_ENCRYPTION_KEY} ${ARCANE_JWT_SECRET}' < "$TEMPLATE_FILE" > "$OUTPUT_FILE"

echo "> Copying to Proxmox snippets..."
cp "$OUTPUT_FILE" "$SNIPPETS_DIR/user-data"

# Make sure new ign is used and start VM
echo "> Configuring VM $VM_ID..."
qm set "$VM_ID" --cicustom "user=local:snippets/user-data"

echo "> Regenerating Cloud-Init image..."
qm cloudinit update "$VM_ID"

echo "> Starting VM $VM_ID..."
qm start "$VM_ID"

echo "> Done."
