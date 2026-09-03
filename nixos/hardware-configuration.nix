{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    # Per-stack `d /mnt/...` tmpfiles rules, GENERATED from the compose files
    # — see nixos/generate-stack-dirs.py for the why. Do not hand-edit; the
    # stack-dirs-generated lint regenerates and byte-compares.
    #
    # 🚨 Flakes only see git-tracked files — `git add` nixos/stack-dirs.nix
    # before any `nixos-rebuild --flake` or the import resolves to nothing.
    ./stack-dirs.nix
  ];

  # Boot configuration
  # virtio_blk is load-bearing: the OS disk is virtio0 (/dev/vda) — without
  # it the stage-1 initrd cannot see the root disk (same failure class as the
  # VPS 2026-09-03). The scsi modules cover the sda/sdb/sdc data disks.
  boot.initrd.availableKernelModules = [ "ata_piix" "uhci_hcd" "virtio_pci" "virtio_blk" "virtio_scsi" "sd_mod" "sr_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  # Bootloader
  boot.loader.grub = {
    enable = true;
    # The OS disk: virtio0 = /dev/vda. /dev/sda is the scsi1 STATE disk —
    # grub-install on it fails (no BIOS-boot partition), which is the guard
    # that caught this when it was wrong.
    device = "/dev/vda";
  };

  # Root filesystem (OS disk - will be the Proxmox image disk)
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  # Persistent state storage
  fileSystems."/srv" = {
    device = "/dev/disk/by-partlabel/state";
    fsType = "ext4";
    options = [ "defaults" ];
  };

  # Fast storage (SSD) - Docker images/volumes
  fileSystems."/mnt/fast" = {
    device = "/dev/disk/by-partlabel/fast";
    fsType = "ext4";
    options = [ "defaults" ];
  };

  # Slow storage (HDD) - Media/bulk data
  fileSystems."/mnt/slow" = {
    device = "/dev/disk/by-partlabel/slow";
    fsType = "ext4";
    options = [ "defaults" ];
  };

  # Bind mount Docker data directory to fast storage
  fileSystems."/var/lib/docker" = {
    device = "/mnt/fast/docker";
    fsType = "none";
    options = [ "bind" ];
    depends = [ "/mnt/fast" ];
  };

  # ONLY rules NOT derived from a compose file live here; per-stack /mnt bind
  # sources are generated into ./stack-dirs.nix (import above). A rule added
  # here for a compose-mounted path would be invisible to the generator and
  # drift when the stack moves.
  systemd.tmpfiles.rules = [
    # The Komodo deploy plane's compose dir (Core/Periphery/FerretDB/Postgres).
    # root:root — it holds compose + the decrypted .env, no non-root owner.
    "d /srv/komodo 0755 root root -"
    # 1000:1000: stack-git-sync (host) writes project directories here as
    # 1000, decrypt-sops-envs chowns the .env to 1000. Root-owned, the sync
    # could never create a directory — GitOps delivery silently dead (caught
    # by tests/suites/gitops.nix).
    "d /srv/stacks 0755 1000 1000 -"
    # Live-host migration: 'd' only applies its owner when it CREATES the
    # directory, and on the real VM /srv/stacks pre-existed root-owned. 'Z'
    # recursively re-owns on each boot; mode left '-' on purpose so per-file
    # modes (0600 .env vs 0644 compose) stay untouched.
    "Z /srv/stacks - 1000 1000 -"
    # NOT stack-derived: this is the bind SOURCE for the /var/lib/docker mount
    # declared above, i.e. the docker daemon's own storage, not a service's
    # data. 0711 rather than 0755 deliberately — the daemon needs traverse,
    # nothing else needs to list it.
    "d /mnt/fast/docker 0711 root root -"
    "d /var/lib/sops-nix 0700 root root -"
  ];

  # Swap (optional - can be added if needed)
  swapDevices = [ ];

  # Hardware
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
