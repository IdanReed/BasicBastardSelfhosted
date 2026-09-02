#!/usr/bin/env bash
#
# Regenerate nixos/stack-dirs.nix from the compose files.
#
#   ./nixos/generate-stack-dirs.sh
#   git diff nixos/stack-dirs.nix        # the change you are about to ship
#
# Run after adding or moving any /mnt bind mount in stacks/*/compose.yaml or
# komodo/compose.yaml. The `stack-dirs-generated` lint re-runs the generator
# and byte-compares, so forgetting is a build failure.
#
# Ownership is decided in nixos/generate-stack-dirs.py (DIR_NOTES /
# STACK_NOTES). A new stack with /mnt mounts EXITS NONZERO until it has a
# STACK_NOTES entry — root:root is docker's own default, so inheriting it by
# accident is indistinguishable from choosing it.
#
# pyyaml is not in the system python, so this runs under nix-shell — the same
# python3.withPackages the lints use.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

exec nix-shell -p 'python3.withPackages(ps: [ ps.pyyaml ])' --run \
  "python3 '$REPO/nixos/generate-stack-dirs.py' --repo '$REPO' --write"
