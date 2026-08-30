{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
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

  # Ensure required directories exist
  systemd.tmpfiles.rules = [
    "d /srv/arcane 0755 root root -"
    # 1000:1000 = the PUID/PGID Arcane runs as. Root-owned, its git sync can
    # never create a project directory here and its deploys cannot read the
    # 0600 .env files — GitOps delivery silently dead (caught by
    # tests/suites/gitops.nix).
    "d /srv/stacks 0755 1000 1000 -"
    # Live-host migration: tmpfiles 'd' only applies its owner when it CREATES
    # the directory — on the real VM /srv/stacks already existed (root-owned,
    # populated) before the 1000:1000 rule above landed, so 'd' never fixes
    # it. 'Z' recursively re-owns everything on each boot; the mode field is
    # left '-' on purpose so per-file modes (0600 .env vs 0644 compose) stay
    # untouched.
    "Z /srv/stacks - 1000 1000 -"
    "d /mnt/fast/docker 0711 root root -"
    "d /var/lib/sops-nix 0700 root root -"
    # Media stack bind-mount roots (stacks/media/compose.yaml). Declared here
    # rather than left to docker's create-on-mount because docker always
    # creates missing bind sources root-owned at container start — exactly
    # the class of bug that made seerr crash-loop on first deploy (EACCES
    # mkdir; its image runs as uid 1000 and cannot chown, now worked around
    # by the seerr-init oneshot) — and because nothing else would create
    # /mnt/slow/data with the uid the hardlink layout needs. The media suite
    # mirrors this exact set in its tmpfiles block; keep the two in sync.
    #
    # Ownership: root:root is correct for the config roots — the LSIO images
    # (radarr/sonarr/prowlarr/bazarr/qbittorrent) chown per PUID/PGID from a
    # root entrypoint, jellyfin and gluetun run as root, cleanuparr's
    # entrypoint honors PUID/PGID, profilarr runs as root, seerr-init chowns
    # /mnt/fast/seerr/config, and clamav 1.5's /init (VERIFIED by reading
    # the pinned image's entrypoint script) runs as root and does
    # `chown -R clamav:clamav /var/lib/clamav` unconditionally before
    # starting clamd. /mnt/slow/data is 1000:1000: every media container
    # works there as uid 1000 and media-init creates the skeleton with that
    # owner.
    "d /mnt/fast/gluetun 0755 root root -"
    "d /mnt/fast/qbittorrent 0755 root root -"
    "d /mnt/fast/qbittorrent/config 0755 root root -"
    "d /mnt/fast/jellyfin 0755 root root -"
    "d /mnt/fast/jellyfin/config 0755 root root -"
    "d /mnt/fast/jellyfin/cache 0755 root root -"
    "d /mnt/fast/radarr 0755 root root -"
    "d /mnt/fast/radarr/config 0755 root root -"
    "d /mnt/fast/sonarr 0755 root root -"
    "d /mnt/fast/sonarr/config 0755 root root -"
    "d /mnt/fast/prowlarr 0755 root root -"
    "d /mnt/fast/prowlarr/config 0755 root root -"
    "d /mnt/fast/seerr 0755 root root -"
    "d /mnt/fast/seerr/config 0755 root root -"
    "d /mnt/fast/bazarr 0755 root root -"
    "d /mnt/fast/bazarr/config 0755 root root -"
    "d /mnt/fast/profilarr 0755 root root -"
    "d /mnt/fast/profilarr/config 0755 root root -"
    "d /mnt/fast/cleanuparr 0755 root root -"
    "d /mnt/fast/cleanuparr/config 0755 root root -"
    "d /mnt/fast/clamav 0755 root root -"
    "d /mnt/fast/clamav/db 0755 root root -"
    "d /mnt/fast/clamav/scanner 0755 root root -"
    "d /mnt/slow/data 0755 1000 1000 -"
    # Also bind sources in their own right (qbittorrent/scanner mount them
    # directly), so without rules docker would create them root-owned during
    # `up` — media-init heals ownership later, but only because it happens to
    # run as root; don't depend on that.
    "d /mnt/slow/data/downloads 0755 1000 1000 -"
    "d /mnt/slow/data/media 0755 1000 1000 -"
    # Immich stack bind-mount roots (stacks/immich/compose.yaml). root:root
    # everywhere ON PURPOSE: the immich images have no PUID/PGID mechanism and
    # run as root by default (the FAQ's non-root mode is deliberately not used
    # — annex §2/§7.5: tailnet-only, loopback-bound, socketless), so the
    # server/ML write /data and /cache as root; the postgres image chowns
    # pgdata itself from its root entrypoint; and immich-config-init (alpine,
    # root) writes the 0600 immich.json into the config dir. The seerr
    # uid-1000 crash-loop class (finding #14) therefore does not apply, but
    # the 'd' rules still must exist: docker creates missing bind sources at
    # container start with no say over the parent /mnt/fast/immich. The
    # tmpfiles-ownership lint's bind-source parity leg parses this compose
    # file too — keep the set in sync.
    "d /mnt/fast/immich 0755 root root -"
    "d /mnt/fast/immich/pgdata 0755 root root -"
    "d /mnt/fast/immich/model-cache 0755 root root -"
    "d /mnt/fast/immich/config 0755 root root -"
    # The photo originals tree (UPLOAD_LOCATION). Slow tier per the overview's
    # volume column: bulk, sequential.
    "d /mnt/slow/photos 0755 root root -"
  ];

  # Swap (optional - can be added if needed)
  swapDevices = [ ];

  # Hardware
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
