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
#   ./tests/run.sh forwardauth    # heavy: forward-auth pilot (bentopdf) end to end
#   ./tests/run.sh forgejo        # heavy: healthz, admin seed, API repo, push/clone
#   ./tests/run.sh media          # heavy: gluetun kill-switch, x265 guard, EICAR chain
#   ./tests/run.sh immich         # heavy: config render, v3 API, thumbs sans ML, reboot
#   ./tests/run.sh books          # heavy: kavita/abs seeding, OPDS, :ro mounts, hook
#   ./tests/run.sh automation     # heavy: HA storage config, MQTT round trip, frigate
#   ./tests/run.sh tracking       # heavy: bookstack/homebox/karakeep headless seeding
#   ./tests/run.sh firefly        # heavy: remote_user_guard + the healthcheck lie
#   ./tests/run.sh dawarich       # heavy: the force_ssl/sidekiq interlock + seeded admin
#   ./tests/run.sh vaultwarden    # the ADMIN_TOKEN $-mangling regression + backup paths
#   ./tests/run.sh notes-sync     # heavy: rmfakecloud create-once window + the bare 22000 publish
#   ./tests/run.sh util           # glance/it-tools/excalidash: the https-redirect healthcheck trap
#   ./tests/run.sh windmill       # heavy: the seeded dependency cache + admin@windmill.dev retired
#   ./tests/run.sh restore        # the restore DRILL: dumps + a real restic repo round trip
#   ./tests/run.sh tandoor        # heavy: the silent SQLite fallback, proven absent
#   ./tests/run.sh wger           # heavy: admin/adminadmin retired + static files really served
#   ./tests/run.sh mealie         # heavy: changeme@example.com retired + sqlite by decision
#   ./tests/run.sh actual         # heavy: headless bootstrap + login contract
#   ./tests/run.sh wealthfolio    # heavy: argon2 $-quoting login round trip + boot-fatal OIDC pinned
#   ./tests/run.sh gatus          # the host-network bind, proven from another machine
#   ./tests/run.sh beszel         # heavy: the key/token triangle, and real disk numbers
#   ./tests/run.sh samba          # heavy: an authenticated SMB round trip, and a refused one
#   ./tests/run.sh docspace       # heavy: the machine key in play is the one from sops
#   ./tests/run.sh journald-logging # the log driver + the `docker logs` contract
#   ./tests/run.sh disko          # disk-config.nix actually partitions
#   ./tests/run.sh proxmox        # image build gate (also part of all)
#   ./tests/run.sh proxmox-boot   # boots the image: cloud-init key -> sops decrypt
#   ./tests/run.sh stack <name>   # one stack, fast — for iterating on it
#   ./tests/run.sh all            # everything above
#   ./tests/run.sh debug vps      # interactive driver: a live VM and a REPL
#
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="${1:-lints}"

# ServerNotes is a sibling repo, so ../ServerNotes does not exist inside a
# linked git worktree and the lints that read _overview.md cannot evaluate
# there. Point at the main checkout instead:
#   SERVER_NOTES=~/local/projects/server-bkg-stacks/ServerNotes ./tests/run.sh
NIX_ARGS=()
if [ -n "${SERVER_NOTES:-}" ]; then
  NIX_ARGS+=(--arg serverNotes "$SERVER_NOTES")
fi

case "$TARGET" in
  debug)
    SUITE="${2:?usage: run.sh debug <vps|services|tailnet|authentik|paperless|backrest>}"
    # driverInteractive drops you into a Python REPL with the machines
    # available. start_all(), then e.g. headscale_vps.shell_interact() for a
    # root shell inside the guest. This is the only sane way to work out why an
    # assertion failed six minutes into a boot sequence.
    echo "==> Building interactive driver for '$SUITE'"
    nix-build tests "${NIX_ARGS[@]}" -A "driver.$SUITE" -o "result-driver-$SUITE"
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
    #
    # One check lives HERE and not in lints.nix: the nix derivations see a
    # copied source tree with no .git, so only this script can ask what is
    # TRACKED. Build artifacts have been committed twice (images.nix.tmp
    # three times in campaign 1, two __pycache__/*.pyc from locally-executed
    # init scripts in campaign 2) — a silent gap of exactly the shape the
    # lint set exists to close.
    if git rev-parse --git-dir >/dev/null 2>&1; then
      tracked_artifacts=$(git ls-files | grep -E '__pycache__|\.pyc$|\.tmp$|^result' || true)
      if [ -n "$tracked_artifacts" ]; then
        echo "FAIL tracked-artifacts: build artifacts are committed:" >&2
        echo "$tracked_artifacts" | sed 's/^/    /' >&2
        echo "  fix: git rm -r --cached <path>  (and check .gitignore covers it)" >&2
        exit 1
      fi
    fi
    exec nix-build tests "${NIX_ARGS[@]}" -A checks.lints --no-out-link
    ;;

  stack)
    NAME="${2:?usage: run.sh stack <name>   (see stackChecks in tests/default.nix)}"
    exec nix-build tests "${NIX_ARGS[@]}" -A "stackChecks.$NAME" --no-out-link
    ;;

  disko)
    exec nix-build tests "${NIX_ARGS[@]}" -A diskoTest --no-out-link
    ;;

  proxmox-boot)
    # Boots the image recipe with a NoCloud seed and asserts the age key +
    # sops decryption via the guest agent. `proxmox` (below) is the build-only
    # gate for the real VMA artifact.
    exec nix-build tests "${NIX_ARGS[@]}" -A proxmoxBoot --no-out-link
    ;;

  vps | services | tailnet | authentik | paperless | backrest | rotation | gitops | forwardauth | forgejo | media | immich | books | automation | tracking | firefly | dawarich | vaultwarden | notes-sync | util | windmill | restore | tandoor | wger | mealie | actual | wealthfolio | gatus | docspace | beszel | samba | journald-logging)
    exec nix-build tests "${NIX_ARGS[@]}" -A "checks.$TARGET" --no-out-link
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
    nix-build tests "${NIX_ARGS[@]}" -A all --no-out-link
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
