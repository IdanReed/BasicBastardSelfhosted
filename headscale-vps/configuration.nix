{ config, pkgs, lib, ... }:

{
  # System identity
  networking.hostName = "headscale-vps";
  system.stateVersion = "25.11";
  time.timeZone = "UTC";

  # Boot configuration for Hetzner Cloud (legacy MBR boot).
  # The install device is NOT set here: disk-config.nix declares an EF02 BIOS
  # boot partition, and disko derives boot.loader.grub.devices from it. Setting
  # `device` as well produces a duplicate entry and trips the
  # "cannot have duplicated devices in mirroredBoots" assertion.
  boot.loader.grub.enable = true;

  # Networking - Hetzner provides DHCP for IPv4
  networking = {
    useDHCP = true;
    interfaces.eth0.useDHCP = true;

    firewall = {
      enable = true;
      allowedTCPPorts = [
        22    # SSH
        80    # Headscale ACME HTTP-01 challenge
        443   # Headscale API + embedded DERP
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

  # Docker for Authentik only. Headscale runs as a native systemd service
  # (modules/headscale.nix) so that the tailnet does not depend on the
  # container runtime being healthy.
  virtualisation.docker = {
    enable = true;
    # nixos-25.11's default `docker` attr is still 28.x, which nixpkgs marks
    # insecure ("unmaintained since November 2025"). 29.x carries no known
    # vulnerabilities.
    package = pkgs.docker_29;
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
  ];

  # SOPS configuration
  sops = {
    defaultSopsFile = ./.sops.env;
    defaultSopsFormat = "dotenv";
    age.keyFile = "/var/lib/sops-nix/sops_age_key.txt";

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

  # Ensure directories exist.
  # Only Authentik needs host paths now — Headscale's state lives in
  # /var/lib/headscale, created by the service's own StateDirectory.
  systemd.tmpfiles.rules = [
    "d /srv/authentik 0755 root root -"
    "d /srv/authentik/pgdata 0700 root root -"
    "d /srv/authentik/redis 0755 root root -"
    "d /srv/authentik/media 0755 root root -"
    "d /srv/authentik/certs 0755 root root -"
    "d /srv/authentik/templates 0755 root root -"
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
