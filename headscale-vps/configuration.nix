{ config, pkgs, lib, ... }:

{
  # System identity
  networking.hostName = "headscale-vps";
  system.stateVersion = "25.11";
  time.timeZone = "UTC";

  # Boot configuration for Hetzner Cloud
  boot.loader.grub = {
    enable = true;
    device = "/dev/sda";  # MBR boot
  };

  # Networking - Hetzner provides DHCP for IPv4
  networking = {
    useDHCP = true;
    interfaces.eth0.useDHCP = true;

    firewall = {
      enable = true;
      allowedTCPPorts = [
        22    # SSH
        80    # HTTP (ACME challenge)
        443   # HTTPS (Headscale + Authentik)
        9000  # Authentik HTTP
        9443  # Authentik HTTPS
      ];
      allowedUDPPorts = [
        3478  # STUN (DERP/NAT traversal)
      ];
      # Trust Tailscale interface once connected
      trustedInterfaces = [ "tailscale0" ];
    };
  };

  # User configuration
  users.users.idan = {
    isNormalUser = true;
    extraGroups = [ "wheel" "docker" ];
    shell = pkgs.bash;
    openssh.authorizedKeys.keys = [
      # TODO: Add your SSH public key here
      # "ssh-ed25519 AAAA... idan@desktop"
    ];
  };

  # Allow passwordless sudo for wheel group
  security.sudo.wheelNeedsPassword = false;

  # SSH server
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
    };
  };

  # Docker for Authentik + Headscale
  virtualisation.docker = {
    enable = true;
    autoPrune = {
      enable = true;
      dates = "weekly";
    };
  };

  # Tailscale (joins its own network)
  services.tailscale.enable = true;

  # System packages
  environment.systemPackages = with pkgs; [
    git
    vim
    htop
    curl
    jq
    dig
    sops
    age
    rsync
  ];

  # SOPS configuration
  sops = {
    defaultSopsFile = ./.sops.env;
    defaultSopsFormat = "dotenv";
    age.keyFile = "/var/lib/sops-nix/key.txt";

    secrets = {
      TAILSCALE_AUTH_KEY = { };
    };
  };

  # Tailscale auto-login service
  systemd.services.tailscale-autoconnect = {
    description = "Automatic connection to Tailscale/Headscale";
    after = [ "network-pre.target" "tailscale.service" ];
    wants = [ "network-pre.target" "tailscale.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      # Wait for tailscaled to be ready
      sleep 2

      # Check if already authenticated
      status="$(${pkgs.tailscale}/bin/tailscale status -json | ${pkgs.jq}/bin/jq -r .BackendState)"
      if [ "$status" = "Running" ]; then
        echo "Already connected to Tailscale"
        exit 0
      fi

      # Authenticate (once Headscale is running, change to --login-server)
      ${pkgs.tailscale}/bin/tailscale up \
        --authkey $(cat ${config.sops.secrets.TAILSCALE_AUTH_KEY.path}) \
        --hostname=headscale-vps
    '';
  };

  # Ensure directories exist
  systemd.tmpfiles.rules = [
    "d /srv/stacks 0755 root root -"
    "d /srv/authentik 0755 root root -"
    "d /srv/headscale 0755 root root -"
    "d /srv/headscale/config 0755 root root -"
    "d /srv/headscale/data 0755 root root -"
    "d /srv/repo 0755 root root -"
    "d /var/lib/sops-nix 0700 root root -"
  ];

  # Fail2ban for SSH protection
  services.fail2ban = {
    enable = true;
    maxretry = 3;
    bantime = "1h";
    jails = {
      sshd = {
        settings = {
          enabled = true;
          port = "ssh";
          filter = "sshd";
          maxretry = 3;
          bantime = "1h";
        };
      };
    };
  };

  # Nix settings
  nix = {
    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      auto-optimise-store = true;
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
  };
}
