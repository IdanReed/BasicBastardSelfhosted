#!/usr/bin/env bash
#
# Regenerate nixos/stack-dirs.nix from the compose files. Run after adding or
# moving any /mnt bind mount in stacks/*/compose.yaml or komodo/compose.yaml —
# the `stack-dirs-generated` lint re-runs this and byte-compares.
#
# Ownership is decided in nixos/generate-stack-dirs.py (DIR_NOTES /
# STACK_NOTES); a new stack with /mnt mounts exits nonzero until it has an
# entry there.
#
# nix-shell because pyyaml is not in the system python.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

exec nix-shell -p 'python3.withPackages(ps: [ ps.pyyaml ])' --run \
  "python3 '$REPO/nixos/generate-stack-dirs.py' --repo '$REPO' --write"
