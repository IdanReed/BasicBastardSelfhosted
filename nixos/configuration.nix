{ config, pkgs, lib, ... }:

{
  # System identity
  networking.hostName = "services-vm";
  system.stateVersion = "25.11";

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
    git
    vim
    htop
    curl
    jq
    sops       # For decrypting stack secrets
    age        # For sops age encryption
    cloud-utils # For growpart (online disk resize)
  ];

  # grow-disk: Online resize after expanding disk in Proxmox
  # Usage: sudo grow-disk srv|fast|slow
  environment.shellAliases.grow-disk = ''
    f() {
      if [ "$(id -u)" -ne 0 ]; then echo "Run with sudo"; return 1; fi
      case "$1" in
        srv)  PART="/dev/disk/by-partlabel/state" ;;
        fast) PART="/dev/disk/by-partlabel/fast" ;;
        slow) PART="/dev/disk/by-partlabel/slow" ;;
        *)    echo "Usage: grow-disk srv|fast|slow"; return 1 ;;
      esac
      DEV=$(readlink -f "$PART")
      DISK=$(echo "$DEV" | sed 's/[0-9]*$//')
      PARTNUM=$(echo "$DEV" | grep -o '[0-9]*$')
      echo "==> Resizing $1: $DEV (disk: $DISK, partition: $PARTNUM)"
      echo "Before: $(df -h "$DEV" | tail -1 | awk '{print $2}')"
      echo "==> Rescanning disk..."
      echo 1 > /sys/class/block/$(basename "$DISK")/device/rescan
      sleep 1
      echo "==> Growing partition..."
      growpart "$DISK" "$PARTNUM"
      echo "==> Growing filesystem..."
      resize2fs "$DEV"
      echo "After:  $(df -h "$DEV" | tail -1 | awk '{print $2}')"
      echo "==> Done!"
    }; f
  '';

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
      ${pkgs.docker}/bin/docker compose up -d
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
