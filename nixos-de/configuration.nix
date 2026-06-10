{ config, pkgs, inputs, ... }:

{
  system.stateVersion = "24.11";

  nix = {
    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      auto-optimise-store = true;
      substituters = [
        "https://cache.nixos.org"
        "https://nix-community.cachix.org"
        "https://niri.cachix.org"
      ];
      trusted-public-keys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        "niri.cachix.org-1:Wv0OmO7PsuocRKzfDoJ3mulSl7Z6oezYhGhR+3W2964="
      ];
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 14d";
    };
  };

  boot = {
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };
    kernelPackages = pkgs.linuxPackages_latest;

    # === CachyOS Performance: Kernel Parameters ===
    kernelParams = [
      "amd_pstate=active"  # AMD P-State EPP driver for Zen 4
      "zswap.enabled=0"    # Disable zswap (conflicts with ZRAM)
    ];

    # === CachyOS Performance: Sysctl Tuning ===
    kernel.sysctl = {
      # Virtual memory - optimized for ZRAM
      "vm.swappiness" = 150;                  # Prefer ZRAM over cache eviction
      "vm.vfs_cache_pressure" = 50;           # Retain dentries/inodes longer
      "vm.dirty_bytes" = 268435456;           # 256MB - start writeback sooner
      "vm.dirty_background_bytes" = 67108864; # 64MB - background writeback threshold
      "vm.dirty_writeback_centisecs" = 1500;
      "vm.page-cluster" = 0;                  # No swap readahead (ZRAM)

      # Stability
      "kernel.nmi_watchdog" = 0;              # Disable - saves perf counter
      "kernel.printk" = "3 3 3 3";            # Suppress kernel console messages

      # File descriptors
      "fs.file-max" = 2097152;

      # Network
      "net.core.netdev_max_backlog" = 16384;
    };
  };

  # === CachyOS Performance: ZRAM Swap ===
  zramSwap = {
    enable = true;
    algorithm = "zstd";
  };

  networking = {
    hostName = "nixos-desktop";
    networkmanager.enable = true;
    firewall.enable = true;
  };

  time.timeZone = "America/Chicago";

  i18n = {
    defaultLocale = "en_US.UTF-8";
    extraLocaleSettings.LC_TIME = "en_US.UTF-8";
  };

  users.users.idan = {
    isNormalUser = true;
    description = "Idan";
    extraGroups = [ "wheel" "networkmanager" "video" "audio" ];
    shell = pkgs.zsh;
  };

  programs.zsh.enable = true;

  programs.niri = {
    enable = true;
    package = inputs.niri.packages.${pkgs.stdenv.hostPlatform.system}.niri-unstable;
  };

  services.xserver.enable = false;

  services.gvfs.enable = true;

  xdg.portal = {
    enable = true;
    extraPortals = [
      pkgs.xdg-desktop-portal-gtk
      pkgs.xdg-desktop-portal-gnome   # provides screencast for OBS/Wayland capture
    ];
  };

  # OBS virtual camera (for Zoom/Meet "use OBS output as webcam")
  boot.kernelModules = [ "v4l2loopback" ];
  boot.extraModulePackages = [ config.boot.kernelPackages.v4l2loopback ];

  services.greetd = {
    enable = true;
    settings = {
      default_session = {
        command = "${pkgs.greetd.tuigreet}/bin/tuigreet --time --cmd niri-session";
        user = "greeter";
      };
      initial_session = {
        command = "niri-session";
        user = "idan";
      };
    };
  };

  security.rtkit.enable = true;

  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    wireplumber.enable = true;
  };

  fonts = {
    enableDefaultPackages = true;
    packages = with pkgs; [
      nerd-fonts.jetbrains-mono
      nerd-fonts.fira-code
      noto-fonts
      noto-fonts-cjk-sans
      noto-fonts-color-emoji
    ];
  };

  environment.systemPackages = with pkgs; [
    git curl wget ripgrep fd jq unzip htop btop
    wl-clipboard xdg-utils grim slurp
    gcc gnumake
  ];

  security.polkit.enable = true;
  nixpkgs.config.allowUnfree = true;

  # === CachyOS Performance: I/O Schedulers ===
  services.udev.extraRules = ''
    # HDD - use BFQ for fair queuing
    ACTION=="add|change", KERNEL=="sd[a-z]*", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
    # SATA SSD - use mq-deadline for low latency
    ACTION=="add|change", KERNEL=="sd[a-z]*", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
    # NVMe - no scheduler (NVMe has its own efficient queuing)
    ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/scheduler}="none"
    # SATA link power management - max performance
    ACTION=="add", SUBSYSTEM=="scsi_host", KERNEL=="host*", ATTR{link_power_management_policy}="max_performance"
  '';

  # === CachyOS Performance: Process Prioritization ===
  services.ananicy = {
    enable = true;
    package = pkgs.ananicy-cpp;
    rulesProvider = pkgs.ananicy-rules-cachyos;
  };

  # === CachyOS Performance: Systemd Tuning ===
  systemd.settings.Manager = {
    DefaultTimeoutStartSec = "15s";
    DefaultTimeoutStopSec = "1s";
    DefaultLimitNOFILE = "2048:2097152";
  };

  systemd.user.extraConfig = ''
    DefaultTimeoutStartSec=15s
    DefaultTimeoutStopSec=1s
    DefaultLimitNOFILE=1024:1048576
  '';

  services.journald.extraConfig = ''
    SystemMaxUse=50M
  '';

  # === CachyOS Performance: NTP Servers ===
  services.timesyncd = {
    enable = true;
    servers = [
      "time.cloudflare.com"
      "time.google.com"
    ];
  };
}
