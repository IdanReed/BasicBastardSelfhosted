{ config, pkgs, lib, ... }:

{
  # System identity
  networking.hostName = "docker-host";
  system.stateVersion = "24.11";

  # Timezone
  time.timeZone = "America/Chicago";

  # Silence kernel console messages
  boot.kernel.sysctl."kernel.printk" = "1 1 1 1";

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

  # Docker
  virtualisation.docker = {
    enable = true;
    autoPrune = {
      enable = true;
      dates = "weekly";
    };
  };

  # System packages
  environment.systemPackages = with pkgs; [
    docker-compose
    git
    vim
    htop
    curl
    jq
    sops       # For decrypting stack secrets
    age        # For sops age encryption
  ];

  # Tailscale
  services.tailscale.enable = true;

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
    description = "Automatic connection to Tailscale";
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

      # Authenticate
      ${pkgs.tailscale}/bin/tailscale up --authkey $(cat ${config.sops.secrets.TAILSCALE_AUTH_KEY.path}) --accept-routes
    '';
  };

  # Decrypt all .sops.env files to .env (for arcane and stacks)
  # Uses the same age key that sops-nix uses for host secrets
  systemd.services.decrypt-sops-envs = {
    description = "Decrypt .sops.env files to .env";
    after = [ "srv.mount" ];
    requires = [ "srv.mount" ];
    wantedBy = [ "multi-user.target" ];

    path = [ pkgs.sops ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      export SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt

      # Decrypt arcane secrets
      if [ -f /srv/arcane/.sops.env ]; then
        sops -d /srv/arcane/.sops.env > /srv/arcane/.env
        chmod 600 /srv/arcane/.env
      fi

      # Decrypt all stack secrets
      for f in /srv/stacks/*/.sops.env; do
        [ -f "$f" ] && sops -d "$f" > "$(dirname "$f")/.env" && chmod 600 "$(dirname "$f")/.env"
      done
    '';
  };

  # Arcane bootstrap service
  systemd.services.bootstrap-arcane = {
    description = "Bootstrap Arcane Docker Management";
    after = [ "docker.service" "network-online.target" "srv.mount" "decrypt-sops-envs.service" ];
    wants = [ "network-online.target" ];
    requires = [ "docker.service" "srv.mount" "decrypt-sops-envs.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      WorkingDirectory = "/srv/arcane";
    };

    script = ''
      # Wait for docker to be fully ready
      sleep 5

      # Start arcane
      ${pkgs.docker-compose}/bin/docker-compose up -d
    '';
  };

  # Firewall - allow Tailscale and local services
  networking.firewall = {
    enable = true;
    trustedInterfaces = [ "tailscale0" ];
    allowedTCPPorts = [
      22    # SSH
      10000 # Arcane
    ];
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
