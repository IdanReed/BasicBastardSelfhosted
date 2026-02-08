#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")"

VM_ID="${1:?Usage: $0 VM_ID}"
IMAGE="/root/flatcar_production_proxmoxve_image.img"

if [[ ! -f "$IMAGE" ]]; then
    echo "> Error: $IMAGE not found in $(pwd)"
    exit 1
fi

echo "> Stopping VM $VM_ID..."
qm stop "$VM_ID" 2>/dev/null || true

echo "> Detaching old OS disk..."
qm set "$VM_ID" --delete scsi0

echo "> Importing fresh OS image..."
IMPORT_OUTPUT=$(qm disk import "$VM_ID" "$IMAGE" local-zfs 2>&1)
echo "$IMPORT_OUTPUT"

# Extract disk name from import output (e.g., "local-zfs:vm-110-disk-4")
DISK_NAME=$(echo "$IMPORT_OUTPUT" | grep -oP 'local-zfs:vm-\d+-disk-\d+' | tail -1)
if [[ -z "$DISK_NAME" ]]; then
    echo "> Error: Could not determine imported disk name"
    exit 1
fi
echo "> Imported as $DISK_NAME"

echo "> Attaching OS disk..."
qm set "$VM_ID" --scsi0 "$DISK_NAME,serial=flatcar-os,ssd=1,discard=on,iothread=1"
qm set "$VM_ID" --boot order=scsi0

echo "> Done. OS disk reimported for VM $VM_ID."
echo "> Run ./build_proxmox.sh $VM_ID to deploy config and start."
