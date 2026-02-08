#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")"

VM_ID="${1:?Usage: $0 VM_ID}"
ENV_FILE=".env"
SOPS_FILE="flatcar.sops.env"
TEMPLATE_FILE="flatcar.ign.tmpl"
OUTPUT_FILE="flatcar.ign"
SNIPPETS_DIR="/var/lib/vz/snippets"

if [[ ! -f "$TEMPLATE_FILE" ]]; then
    echo "Error: $TEMPLATE_FILE not found"
    echo "Run ./build_windows.sh on Windows first"
    exit 1
fi

cleanup() {
    rm -f "$ENV_FILE"
}
trap cleanup EXIT

echo "Decrypting secrets..."
sops -d "$SOPS_FILE" > "$ENV_FILE"

echo "Loading environment..."
set -a
source "$ENV_FILE"
set +a

echo "Substituting variables..."
envsubst '${SSH_AUTHORIZED_KEY} ${TAILSCALE_AUTH_KEY}' < "$TEMPLATE_FILE" > "$OUTPUT_FILE"

echo "Copying to Proxmox snippets..."
cp "$OUTPUT_FILE" "$SNIPPETS_DIR/user-data"

echo "Configuring VM $VM_ID..."
qm set "$VM_ID" --cicustom "user=local:snippets/user-data"

echo "Regenerating Cloud-Init image..."
qm cloudinit update "$VM_ID"

echo "Done."
echo "Apply changes: flatcar-reset -> qm stop $VM_ID && qm start $VM_ID"
