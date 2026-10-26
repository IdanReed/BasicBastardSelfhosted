#!/usr/bin/env bash
#
# Rebuilds the NixOS image and imports it to Proxmox — first-time setup or a
# full OS re-image. Run on the Proxmox host.
#
# Usage: ./rebuild_os_proxmox.sh VM_ID [--build]
#   --build: also build the image (otherwise expects it in ./result/)

set -euo pipefail

cd "$(dirname "$0")"

VM_ID="${1:?Usage: $0 VM_ID [--build]}"
BUILD_IMAGE="${2:-}"

if [[ "$BUILD_IMAGE" == "--build" ]]; then
    echo "> Building NixOS Proxmox image..."
    # The image recipe lives in the repo-root flake; the out-link stays here.
    nix build ..#proxmox-image
fi

# The image name carries the nixpkgs version (vzdump-qemu-nixos-<ver>.vma.zst),
# so glob rather than pin a name that drifts every channel bump. Resolved after
# the build, or a first run would never see the image it just made.
IMAGE_PATH=$(ls ./result/vzdump-qemu-*.vma.zst 2>/dev/null | head -1 || true)

if [[ -z "$IMAGE_PATH" || ! -f "$IMAGE_PATH" ]]; then
    echo "> Error: no vzdump-qemu-*.vma.zst under ./result/"
    echo "> Run with --build flag or build manually with: nix build ..#proxmox-image"
    exit 1
fi

echo "> Stopping VM $VM_ID..."
qm stop "$VM_ID" 2>/dev/null || true

echo "> Restoring NixOS image..."
# qmrestore reads .vma.zst natively — not `qm disk import`, which expects a
# disk image rather than a vzdump archive. --force replaces the whole VM;
# build_proxmox.sh re-applies the cloud-init wiring afterwards.
qmrestore "$IMAGE_PATH" "$VM_ID" --storage local-zfs --force

echo "> Done. OS reimported for VM $VM_ID."
echo "> Run ./build_proxmox.sh $VM_ID to inject secrets and start."
