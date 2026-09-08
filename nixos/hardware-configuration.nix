{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    # GENERATED per-stack `d /mnt/...` rules — edit nixos/generate-stack-dirs.py
    # and regenerate; the stack-dirs-generated lint byte-compares.
    #
    # Flakes only see git-tracked files: `git add nixos/stack-dirs.nix` before
    # any `nixos-rebuild --flake` or this import resolves to nothing.
    ./stack-dirs.nix
  ];

  # Boot
  # virtio_blk is load-bearing: the OS disk is virtio0 (/dev/vda) and without
  # it stage-1 cannot see root. The scsi modules cover the sda/sdb/sdc data
  # disks. kvm-intel is for nested virt, which the Forgejo runner's VM suites
  # need.
  boot.initrd.availableKernelModules = [ "ata_piix" "uhci_hcd" "virtio_pci" "virtio_blk" "virtio_scsi" "sd_mod" "sr_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  boot.loader.grub = {
    enable = true;
    # virtio0 = /dev/vda. /dev/sda is the scsi1 STATE disk; grub-install on it
    # fails for want of a BIOS-boot partition.
    device = "/dev/vda";
  };

  # Filesystems
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  # Persistent state (compose files, komodo state)
  fileSystems."/srv" = {
    device = "/dev/disk/by-partlabel/state";
    fsType = "ext4";
    options = [ "defaults" ];
  };

  # SSD: configs and databases
  fileSystems."/mnt/fast" = {
    device = "/dev/disk/by-partlabel/fast";
    fsType = "ext4";
    options = [ "defaults" ];
  };

  # HDD: bulk media
  fileSystems."/mnt/slow" = {
    device = "/dev/disk/by-partlabel/slow";
    fsType = "ext4";
    options = [ "defaults" ];
  };

  fileSystems."/var/lib/docker" = {
    device = "/mnt/fast/docker";
    fsType = "none";
    options = [ "bind" ];
    depends = [ "/mnt/fast" ];
  };

  # Tmpfiles
  # ONLY rules NOT derived from a compose file belong here; per-stack /mnt bind
  # sources are generated into ./stack-dirs.nix above.
  systemd.tmpfiles.rules = [
    # Holds the komodo compose and its decrypted .env — no non-root owner.
    "d /srv/komodo 0755 root root -"
    # 1000:1000 (finding #10): stack-git-sync writes project directories here
    # as 1000 and decrypt-sops-envs chowns each .env to it. Root-owned, GitOps
    # delivery is silently dead.
    "d /srv/stacks 0755 1000 1000 -"
    # 'd' applies its owner only when it CREATES the directory, and on the live
    # VM /srv/stacks pre-existed root-owned. Mode left '-' so per-file modes
    # (0600 .env vs 0644 compose) stay untouched.
    "Z /srv/stacks - 1000 1000 -"
    # Bind SOURCE for the /var/lib/docker mount above — the daemon's own
    # storage. 0711: it needs traverse, nothing else needs to list it.
    "d /mnt/fast/docker 0711 root root -"
    "d /var/lib/sops-nix 0700 root root -"
  ];

  swapDevices = [ ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
