#!/usr/bin/env bash
#
# Regenerate nixos/stack-dirs.nix from the compose files.
#
#   ./nixos/generate-stack-dirs.sh
#   git diff nixos/stack-dirs.nix        # the change you are about to ship
#
# Run this after adding or moving any /mnt bind mount in stacks/*/compose.yaml
# or komodo/compose.yaml. The `stack-dirs-generated` lint re-runs the same
# generator and byte-compares against the checked-in file, so forgetting is a
# build failure rather than 13 silently missing tmpfiles rules (which is
# exactly what the hand-maintained list it replaced produced).
#
# Ownership is decided in nixos/generate-stack-dirs.py — DIR_NOTES for the
# non-root cases and STACK_NOTES for the per-stack prose. A new stack with
# /mnt mounts makes the generator EXIT NONZERO until it has a STACK_NOTES
# entry; that is deliberate. root:root is docker's own default, so inheriting
# it by accident is indistinguishable from choosing it, and this fleet has
# been bitten by that four times.
#
# pyyaml is not in the system python, so this runs under nix-shell — the same
# python3.withPackages the lints use.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

exec nix-shell -p 'python3.withPackages(ps: [ ps.pyyaml ])' --run \
  "python3 '$REPO/nixos/generate-stack-dirs.py' --repo '$REPO' --write"
