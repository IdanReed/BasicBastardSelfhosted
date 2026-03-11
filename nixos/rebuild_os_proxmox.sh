#!/bin/bash
#
# Rebuilds the NixOS image and imports it to Proxmox.
# Run this for first-time setup or full OS re-image.
#
# Usage: ./rebuild_os_proxmox.sh VM_ID [--build]
#   --build: Also build the image (otherwise expects it in ./result/)

set -euo pipefail

cd "$(dirname "$0")"

VM_ID="${1:?Usage: $0 VM_ID [--build]}"
BUILD_IMAGE="${2:-}"

IMAGE_PATH="./result/vzdump-qemu-nixos.vma.zst"

# Build image if requested
if [[ "$BUILD_IMAGE" == "--build" ]]; then
    echo "> Building NixOS Proxmox image..."
    nix build .#proxmox-image
fi

# Check image exists
if [[ ! -f "$IMAGE_PATH" ]]; then
    echo "> Error: Image not found at $IMAGE_PATH"
    echo "> Run with --build flag or build manually with: nix build .#proxmox-image"
    exit 1
fi

echo "> Stopping VM $VM_ID..."
qm stop "$VM_ID" 2>/dev/null || true

echo "> Detaching old OS disk..."
qm set "$VM_ID" --delete scsi0 2>/dev/null || true

echo "> Importing NixOS image..."
# Decompress and restore the VMA
TEMP_VMA=$(mktemp)
trap "rm -f $TEMP_VMA" EXIT
zstd -d "$IMAGE_PATH" -o "$TEMP_VMA"

# Use qmrestore to import (creates new disk automatically)
# Note: This may need adjustment based on your Proxmox storage setup
IMPORT_OUTPUT=$(qm disk import "$VM_ID" "$TEMP_VMA" local-zfs 2>&1) || {
    # Alternative: use qmrestore for VMA files
    echo "> Trying qmrestore method..."
    qmrestore "$TEMP_VMA" "$VM_ID" --storage local-zfs --force
    echo "> Done with qmrestore."
    exit 0
}

echo "$IMPORT_OUTPUT"

# Extract disk name from import output
DISK_NAME=$(echo "$IMPORT_OUTPUT" | grep -oP 'local-zfs:vm-\d+-disk-\d+' | tail -1)
if [[ -z "$DISK_NAME" ]]; then
    echo "> Error: Could not determine imported disk name"
    exit 1
fi
echo "> Imported as $DISK_NAME"

echo "> Attaching OS disk..."
qm set "$VM_ID" --scsi0 "$DISK_NAME,ssd=1,discard=on,iothread=1"
qm set "$VM_ID" --boot order=scsi0

echo "> Done. OS disk reimported for VM $VM_ID."
echo "> Run ./build_proxmox.sh $VM_ID to inject secrets and start."
