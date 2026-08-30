# Disk layout test for headscale-vps/disk-config.nix, using disko's own
# makeDiskoTest at the exact revision the host pins (diskoSource comes from
# headscale-vps/flake.lock via lib/sources.nix, wired up in tests/default.nix).
#
# This is the ONLY coverage disk-config.nix has. The VM suites deliberately
# exclude it: they run on the test driver's own image with
# profiles.noBootloader, so neither the partitioning nor the grub install path
# is ever exercised there. Without this test, the first thing to apply an
# edited disk-config.nix is nixos-anywhere — which wipes the real VPS before
# finding out the config no longer formats, mounts, or boots.
#
# What makeDiskoTest actually does with the config, in order:
#   1. formats and mounts it on a blank qemu disk, and re-runs both to prove
#      they are idempotent (nixos-anywhere relies on exactly these scripts);
#   2. installs a minimal NixOS onto the result and reboots into it — with
#      efi = false, matching Hetzner's legacy-MBR boot. Booting at all proves
#      the EF02 partition is present and grub can install to the disk. Caveat:
#      makeDiskoTest sets boot.loader.grub.devices itself (mkOverride 70, from
#      its prepareDiskoConfig scaffolding), overriding the derivation in
#      disko's gpt.nix module — the one headscale-vps/configuration.nix
#      actually relies on (it sets no boot.loader.grub.devices of its own —
#      see the comment there). Both derivations key on `type == "EF02"`, so an
#      edit to disk-config.nix that drops or retypes EF02 IS caught; a disko
#      bump that regresses gpt.nix's own derivation is NOT. This test covers
#      the disk-config contract, not the module mechanism;
#   3. runs extraTestScript inside the booted system.
#
# Deviation from production, inherent to makeDiskoTest: the device is rewritten
# from /dev/sda to the test runner's virtio disks (prepareDiskoConfig), so the
# literal device path — the one Hetzner-specific fact in the file — is not
# covered either. Everything else (GPT label, EF02 + root layout, ext4,
# mountpoint) is the real config.

{
  pkgs,
  lib,
  diskoSource,
}:

let
  # disko's testLib defaults its nixpkgs helpers to <nixpkgs>, which the
  # harness deliberately does not provide (no NIX_PATH dependence — see
  # tests/default.nix). Pass them explicitly from the pinned nixpkgs.
  #
  # qemu-common needs a shim: the pinned disko revision calls it with
  # { lib, stdenv } (tracking nixpkgs-unstable's signature), but nixos-25.11's
  # nixos/lib/qemu-common.nix still takes { lib, pkgs }. The shim ignores the
  # arguments and closes over the harness pkgs — safe because makeDiskoTest is
  # only ever invoked with this same pkgs below.
  # The pinned disko's test lib targets an older nixpkgs test driver: it
  # registers extra VMs via `driver.machines_qemu`, an attribute the
  # nixos-25.11 driver no longer has (it is plain `driver.machines` now), so
  # every makeDiskoTest run died with AttributeError before asserting anything.
  # Patch the ONE line. Production consumes only disko's module — this touches
  # test tooling exclusively, so the host pin does not drift.
  patchedDiskoSource = pkgs.applyPatches {
    name = "disko-testlib-driver-api";
    src = diskoSource;
    postPatch = ''
      substituteInPlace lib/tests.nix \
        --replace-fail "driver.machines_qemu.append(machine)" \
                       "driver.machines.append(machine)"
    '';
  };

  diskoLib = import "${patchedDiskoSource}/lib" {
    inherit lib;
    makeTest = import "${pkgs.path}/nixos/tests/make-test-python.nix";
    eval-config = import "${pkgs.path}/nixos/lib/eval-config.nix";
    qemu-common = _: import "${pkgs.path}/nixos/lib/qemu-common.nix" { inherit lib pkgs; };
  };
in
diskoLib.testLib.makeDiskoTest {
  inherit pkgs;
  # makeDiskoTest prefixes "disko-", yielding "disko-headscale-vps".
  name = "headscale-vps";
  disko-config = ../../headscale-vps/disk-config.nix;

  # Hetzner x86_64 cloud VPS boots legacy MBR, not UEFI. This also forces the
  # installed system onto grub (systemd-boot defaults off without efi), which
  # is what the real host runs.
  efi = false;

  # Runs in the system booted FROM the formatted disk, after local-fs.target.
  extraTestScript = ''
    # Root really is the ext4 the config declares — not tmpfs, not a fallback.
    machine.succeed("findmnt -no FSTYPE / | grep -qx ext4")

    # The EF02 BIOS-boot partition exists on the booted disk. Its GPT type
    # GUID is what disko keys on to derive boot.loader.grub.devices; if a
    # disk-config.nix edit drops or retypes it, the legacy-boot chain — and
    # this grep — breaks. (/dev/vda is what prepareDiskoConfig rewrote the
    # disk to for the booted machine.)
    machine.succeed("lsblk -no PARTTYPE /dev/vda | grep -qi 21686148-6449-6e6f-744e-656564454649")
  '';
}
