{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    # Every per-stack `d /mnt/...` tmpfiles rule, GENERATED from the compose
    # files by nixos/generate-stack-dirs.sh and checked in. It is a separate
    # file because nixos/ is its own flake root and cannot read ../stacks/ at
    # eval time (the constraint that also triplicates ssh-pubkeys.nix), so the
    # only way to keep the rules honest is to generate them and have a lint
    # regenerate + byte-compare. Do not hand-edit it; edit the generator.
    #
    # 🚨 It is a NEW file, and flakes only see git-tracked files — `git add`
    # nixos/stack-dirs.nix before any `nixos-rebuild --flake` or the import
    # resolves to nothing.
    ./stack-dirs.nix
  ];

  # Boot configuration
  boot.initrd.availableKernelModules = [ "ata_piix" "uhci_hcd" "virtio_pci" "virtio_scsi" "sd_mod" "sr_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  # Bootloader
  boot.loader.grub = {
    enable = true;
    device = "/dev/sda";
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

  # Ensure required directories exist.
  #
  # ONLY the rules that are not derived from a compose file live here. Every
  # per-stack /mnt bind-mount source (and its parents) is generated into
  # ./stack-dirs.nix — see the import above. A rule added here for a path some
  # compose file mounts would be invisible to that generator and would drift
  # the moment the stack moved, which is the failure this whole split exists
  # to end.
  systemd.tmpfiles.rules = [
    # The Komodo deploy plane's compose dir (Core/Periphery/FerretDB/Postgres).
    # root:root — it holds compose + the decrypted .env, no non-root owner.
    "d /srv/komodo 0755 root root -"
    # 1000:1000: stack-git-sync (host) writes project directories here as 1000,
    # and decrypt-sops-envs chowns the .env to 1000. Root-owned, the sync could
    # never create a project directory here — GitOps delivery silently dead
    # (caught by tests/suites/gitops.nix). Periphery runs as root and reads the
    # 0600 .env regardless, so 1000 no longer strictly binds but is preserved.
    "d /srv/stacks 0755 1000 1000 -"
    # Live-host migration: tmpfiles 'd' only applies its owner when it CREATES
    # the directory — on the real VM /srv/stacks already existed (root-owned,
    # populated) before the 1000:1000 rule above landed, so 'd' never fixes
    # it. 'Z' recursively re-owns everything on each boot; the mode field is
    # left '-' on purpose so per-file modes (0600 .env vs 0644 compose) stay
    # untouched.
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
