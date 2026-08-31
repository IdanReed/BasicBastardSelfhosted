#!/usr/bin/env bash
#
# Entry point for the test harness. See ./README.md.
#
#   ./tests/run.sh                # lints only — seconds, run this constantly
#   ./tests/run.sh vps            # VPS: caddy + headscale + a real tailnet
#   ./tests/run.sh services       # services VM: sops -> arcane -> stacks
#   ./tests/run.sh tailnet        # both hosts on one tailnet, end to end
#   ./tests/run.sh authentik      # heavy: blueprint + OIDC secret contract
#   ./tests/run.sh paperless      # heavy: full stack, document pipeline
#   ./tests/run.sh backrest       # heavy: config seeding + the key gate
#   ./tests/run.sh rotation       # heavy: secret rotation restarts both consumers
#   ./tests/run.sh gitops         # arcane: push -> sync -> deploy -> update
#   ./tests/run.sh media          # heavy: gluetun kill-switch, x265 guard, EICAR chain
#   ./tests/run.sh immich         # heavy: config render, v3 API, thumbs sans ML, reboot
#   ./tests/run.sh books          # heavy: kavita/abs seeding, OPDS, :ro mounts, hook
#   ./tests/run.sh automation     # heavy: HA storage config, MQTT round trip, frigate
#   ./tests/run.sh disko          # disk-config.nix actually partitions
#   ./tests/run.sh stack <name>   # one stack, fast — for iterating on it
#   ./tests/run.sh all            # everything above
#   ./tests/run.sh debug vps      # interactive driver: a live VM and a REPL
#
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="${1:-lints}"

case "$TARGET" in
  debug)
    SUITE="${2:?usage: run.sh debug <vps|services|tailnet|authentik|paperless|backrest>}"
    # driverInteractive drops you into a Python REPL with the machines
    # available. start_all(), then e.g. headscale_vps.shell_interact() for a
    # root shell inside the guest. This is the only sane way to work out why an
    # assertion failed six minutes into a boot sequence.
    echo "==> Building interactive driver for '$SUITE'"
    nix-build tests -A "driver.$SUITE" -o "result-driver-$SUITE"
    echo
    echo "    Starting the driver. Useful first commands:"
    echo "      start_all()"
    echo "      headscale_vps.shell_interact()   # or services_vm"
    echo "      print(headscale_vps.succeed('systemctl --failed'))"
    echo
    exec "./result-driver-$SUITE/bin/nixos-test-driver"
    ;;

  lints)
    # Pure contract checks. No VM, no images. If these fail, no VM suite is
    # worth starting.
    exec nix-build tests -A checks.lints --no-out-link
    ;;

  stack)
    NAME="${2:?usage: run.sh stack <name>   (see stackChecks in tests/default.nix)}"
    exec nix-build tests -A "stackChecks.$NAME" --no-out-link
    ;;

  disko)
    exec nix-build tests -A diskoTest --no-out-link
    ;;

  proxmox-boot)
    # Boots the image recipe with a NoCloud seed and asserts the age key +
    # sops decryption via the guest agent. `proxmox` (below) is the build-only
    # gate for the real VMA artifact.
    exec nix-build tests -A proxmoxBoot --no-out-link
    ;;

  vps | services | tailnet | authentik | paperless | backrest | rotation | gitops | forwardauth | forgejo | media | immich | books | automation)
    exec nix-build tests -A "checks.$TARGET" --no-out-link
    ;;

  proxmox)
    # Build gate for the Proxmox image path (nixos-generators + cloud-init +
    # qemu guest wiring). A flake build, not a tests attr: the image recipe
    # lives in nixos/flake.nix. Catches eval/build breakage long before a
    # re-image day; the boot-the-image cloud-init suite covers the runtime
    # contract separately.
    exec nix build ./nixos#proxmox-image --no-link --print-build-logs
    ;;

  all)
    nix-build tests -A all --no-out-link
    # The image build gate rides along: "all" should mean all.
    exec nix build ./nixos#proxmox-image --no-link
    ;;

  *)
    echo "unknown target: $TARGET" >&2
    # Print the usage block above: everything from line 3 down to the first
    # non-comment line (so new targets never silently fall off the help).
    sed -n '3,/^set /p' "$0" | sed '$d' >&2
    exit 1
    ;;
esac
