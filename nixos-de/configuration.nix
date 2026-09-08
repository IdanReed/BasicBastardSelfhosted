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

    # CachyOS tuning
    kernelParams = [
      "amd_pstate=active"
      "zswap.enabled=0" # conflicts with ZRAM
    ];

    # CachyOS tuning
    kernel.sysctl = {
      "vm.swappiness" = 150; # ZRAM is cheaper than cache eviction
      "vm.vfs_cache_pressure" = 50;
      "vm.dirty_bytes" = 268435456;
      "vm.dirty_background_bytes" = 67108864;
      "vm.dirty_writeback_centisecs" = 1500;
      "vm.page-cluster" = 0; # no swap readahead on ZRAM
      "kernel.nmi_watchdog" = 0;
      "kernel.printk" = "3 3 3 3";
      "fs.file-max" = 2097152;
      "net.core.netdev_max_backlog" = 16384;
    };
  };

  zramSwap = {
    enable = true;
    algorithm = "zstd";
  };

  networking = {
    hostName = "nixos-desktop";
    # Authentik restricts /if/admin* + /api/v3/* to tailnet/loopback, so
    # reaching auth.idanreed.com over the public IP login-loops.
    extraHosts = "100.64.0.1 auth.idanreed.com";
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
    ];
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

  # OBS virtual camera
  boot.kernelModules = [ "v4l2loopback" ];
  boot.extraModulePackages = [ config.boot.kernelPackages.v4l2loopback ];

  # The module owns services.greetd (default_session = noctalia-greeter-session);
  # setting greetd here would fight it. `settings` writes greeter.toml, which
  # wins over the palette/wallpaper picked in the greeter UI (sync.toml).
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

  # Nothing links this without a display manager, and the greeter's session
  # list comes up empty without it.
  environment.pathsToLink = [ "/share/wayland-sessions" ];

  # Unlock the keyring with the greeter password, so Zed & co. don't re-prompt.
  services.gnome.gnome-keyring.enable = true;
  security.pam.services.greetd.enableGnomeKeyring = true;

  security.rtkit.enable = true;

  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    wireplumber.enable = true;

    # ACP models a GPU audio codec as mutually exclusive profiles, so at most
    # one display is a sink at a time. Raw mode makes every HDMI/DP PCM its own
    # sink, named from the display's ELD. Match display-audio vendors ONLY
    # (0x10de NVIDIA, 0x1002 AMD HDMI) — Intel/AMD analog codecs and USB audio
    # reuse those ids for HDA and still need ACP/UCM for jack + mixer handling.
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

  # Raw mode (ACP off, above) never flips "IEC958 Playback Switch", which
  # defaults to off — every layer then reads healthy (PipeWire links, ALSA
  # RUNNING, valid ELD) and the display is silent. Scoped by eld# nodes in
  # procfs: only display-audio codecs expose those. numids are enumerated, not
  # hardcoded — they are not stable across cards.
  systemd.services.hdmi-iec958-enable = {
    description = "Enable IEC958 playback on display-audio codecs (ACP is off)";
    # After=sleep.target is what makes the sleep.target wantedBy a RESUME hook;
    # without it the unit is unordered against suspend and can run before it.
    after = [ "sound.target" "sleep.target" ];
    wantedBy = [ "multi-user.target" "sleep.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = false;
    };
    script = ''
      shopt -s nullglob
      for dir in /proc/asound/card*/; do
        elds=("$dir"eld#*)
        (( ''${#elds[@]} )) || continue
        card=''${dir%/}; card=''${card##*/card}
        ${pkgs.alsa-utils}/bin/amixer -c "$card" controls 2>/dev/null \
          | grep -F "name='IEC958 Playback Switch'" \
          | sed 's/^numid=\([0-9]*\),.*/\1/' \
          | while read -r numid; do
              ${pkgs.alsa-utils}/bin/amixer -c "$card" cset numid="$numid" on >/dev/null 2>&1 || true
            done
      done
    '';
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

  # CachyOS tuning
  services.udev.extraRules = ''
    # HDD - use BFQ for fair queuing
    ACTION=="add|change", KERNEL=="sd[a-z]*", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
    # SATA SSD - use mq-deadline for low latency
    ACTION=="add|change", KERNEL=="sd[a-z]*", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
    # NVMe - no scheduler (NVMe has its own efficient queuing)
    ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/scheduler}="none"
    # SATA link power management - max performance
    ACTION=="add", SUBSYSTEM=="scsi_host", KERNEL=="host*", ATTR{link_power_management_policy}="max_performance"

    # A codec reprobe (display hotplug, GPU runtime PM) re-registers the card
    # with IEC958 back at its default, so re-run the enable job on card add.
    # See systemd.services.hdmi-iec958-enable above for why that is needed.
    ACTION=="add", SUBSYSTEM=="sound", KERNEL=="card*", TAG+="systemd", ENV{SYSTEMD_WANTS}+="hdmi-iec958-enable.service"
  '';

  # CachyOS tuning
  services.ananicy = {
    enable = true;
    package = pkgs.ananicy-cpp;
    rulesProvider = pkgs.ananicy-rules-cachyos;
  };

  # CachyOS tuning
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

  services.timesyncd = {
    enable = true;
    servers = [
      "time.cloudflare.com"
      "time.google.com"
    ];
  };
}
