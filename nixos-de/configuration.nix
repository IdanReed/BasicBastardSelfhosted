{
  config,
  pkgs,
  inputs,
  ...
}:

{
  system.stateVersion = "24.11";

  nix = {
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
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
      "amd_pstate=active" # AMD P-State EPP driver for Zen 4
      "zswap.enabled=0" # Disable zswap (conflicts with ZRAM)
    ];

    # === CachyOS Performance: Sysctl Tuning ===
    kernel.sysctl = {
      # Virtual memory - optimized for ZRAM
      "vm.swappiness" = 150; # Prefer ZRAM over cache eviction
      "vm.vfs_cache_pressure" = 50; # Retain dentries/inodes longer
      "vm.dirty_bytes" = 268435456; # 256MB - start writeback sooner
      "vm.dirty_background_bytes" = 67108864; # 64MB - background writeback threshold
      "vm.dirty_writeback_centisecs" = 1500;
      "vm.page-cluster" = 0; # No swap readahead (ZRAM)

      # Stability
      "kernel.nmi_watchdog" = 0; # Disable - saves perf counter
      "kernel.printk" = "3 3 3 3"; # Suppress kernel console messages

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
    #networkmanager = {
    #  enable = true;
    #  plugins = [ pkgs.networkmanager-openconnect ];
    #};
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
    extraGroups = [
      "wheel"
      "video"
      "audio"
    ]; # networkmanager
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
      pkgs.xdg-desktop-portal-gnome # provides screencast for OBS/Wayland capture
    ];
  };

  # OBS virtual camera (for Zoom/Meet "use OBS output as webcam")
  boot.kernelModules = [ "v4l2loopback" ];
  boot.extraModulePackages = [ config.boot.kernelPackages.v4l2loopback ];

  # Graphical boot login. The module enables greetd itself and points
  # default_session at noctalia-greeter-session, so don't set services.greetd
  # here — it would fight the module. (Was tuigreet, a text-mode greeter.)
  # Palette/wallpaper are picked in the greeter UI and land in sync.toml;
  # anything set below in `settings` writes greeter.toml, which wins.
  programs.noctalia-greeter = {
    enable = true;
    settings = {
      cursor = {
        theme = "Bibata-Modern-Classic"; # matches stylix.cursor
        size = 24;
        path = "${pkgs.bibata-cursors}/share/icons";
      };
      keyboard.layout = "us";
      user.default = "idan"; # skip the user list, go straight to the password
    };
  };

  # The greeter reads sessions from /run/current-system/sw/share/wayland-sessions,
  # which nothing links without a display manager — tuigreet ran `niri-session`
  # directly and never needed it. Without this the session list comes up empty.
  environment.pathsToLink = [ "/share/wayland-sessions" ];

  # Unlock gnome-keyring with the password entered at the greeter,
  # so apps like Zed don't prompt again after login
  services.gnome.gnome-keyring.enable = true;
  security.pam.services.greetd.enableGnomeKeyring = true;

  security.rtkit.enable = true;

  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    wireplumber.enable = true;

    # Expose EVERY HDMI/DP output as its own sink, each named after whatever
    # display is actually plugged into it — nothing about specific monitors is
    # written down here, so the sink list follows the hardware at boot.
    #
    # The ALSA Card Profile layer models a GPU audio codec as a set of mutually
    # exclusive profiles ("Digital Stereo (HDMI)", "... (HDMI 2)", ...). There is
    # no combined variant — verified by enumerating EnumProfile on this card —
    # so under ACP at most one display is a sink at a time, and it is named
    # after the port rather than the display. Turning ACP off puts the card in
    # raw mode: every HDMI/DP PCM becomes its own sink, and each is named from
    # the ELD the attached display reports ("LG ULTRAGEAR+", "BenQ GL2760");
    # ports with nothing plugged in fall back to "HDMI 2", "HDMI 3".
    #
    # Matched by GPU-audio vendor, so moving a display to another card still
    # gets the same treatment. matches[] is an OR:
    #   0x10de  NVIDIA
    #   0x1002  AMD/ATI — the Radeon HDMI audio function, not the analog codec
    #
    # Intel (0x8086) is deliberately NOT listed: Intel uses that same vendor id
    # for analog HDA controllers, so matching it would strip ACP from a
    # motherboard codec and break its jack/mixer handling. Same reason the
    # analog AMD codec (0x1022) and USB audio are left alone — they need
    # ACP/UCM. Add a vendor here only if it is a display-audio function.
    wireplumber.extraConfig."51-hdmi-all-outputs" = {
      "monitor.alsa.rules" = [
        {
          matches = [
            { "device.vendor.id" = "0x10de"; }
            { "device.vendor.id" = "0x1002"; }
          ];
          actions.update-props."api.alsa.use-acp" = false;
        }
      ];
    };
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
    git
    curl
    wget
    ripgrep
    fd
    jq
    unzip
    htop
    btop
    wl-clipboard
    xdg-utils
    grim
    slurp
    gcc
    gnumake
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
