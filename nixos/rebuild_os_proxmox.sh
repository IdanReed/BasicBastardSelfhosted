#!/usr/bin/env bash
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

echo "> Restoring NixOS image..."
# qmrestore reads .vma.zst natively — no manual decompress (zstd refuses to
# overwrite a mktemp'd file and stages a multi-GB VMA on /tmp, often tmpfs),
# and NOT `qm disk import` (expects a disk image, not a vzdump archive).
# --force replaces the whole VM; config and disks come from the archive, and
# build_proxmox.sh re-applies the cloud-init wiring afterwards.
qmrestore "$IMAGE_PATH" "$VM_ID" --storage local-zfs --force

echo "> Done. OS reimported for VM $VM_ID."
echo "> Run ./build_proxmox.sh $VM_ID to inject secrets and start."
