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
    # nixos-25.11's default `docker` attr is still 28.x, which nixpkgs marks
    # insecure ("unmaintained since November 2025") — that makes the whole
    # configuration refuse to evaluate, not just warn. 29.x carries no known
    # vulnerabilities. Matches headscale-vps/configuration.nix.
    package = pkgs.docker_29;
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

    age.keyFile = "/var/lib/sops-nix/sops_age_key.txt";

    secrets = {
      TAILSCALE_AUTH_KEY = { };
    };
  };

  # Tailscale auto-login service.
  #
  # --login-server is REQUIRED. Without it `tailscale up --authkey` registers
  # against Tailscale's SaaS control plane, and a Headscale-issued preauth key
  # is not valid there — the node silently fails to join the tailnet.
  systemd.services.tailscale-autoconnect = {
    description = "Automatic connection to Headscale";
    after = [ "network-online.target" "tailscale.service" ];
    wants = [ "network-online.target" "tailscale.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # The VPS may still be booting or reissuing certificates. Retry rather
      # than sitting off the tailnet until someone reruns this by hand.
      Restart = "on-failure";
      RestartSec = "30s";
    };

    script = ''
      set -euo pipefail

      # Wait for tailscaled to be ready
      sleep 2

      # Check if already authenticated
      status="$(${pkgs.tailscale}/bin/tailscale status -json | ${pkgs.jq}/bin/jq -r .BackendState)"
      if [ "$status" = "Running" ]; then
        echo "Already connected to Headscale"
        exit 0
      fi

      ${pkgs.tailscale}/bin/tailscale up \
        --login-server=https://headscale.idanreed.com \
        --authkey "$(cat ${config.sops.secrets.TAILSCALE_AUTH_KEY.path})" \
        --hostname=services-vm \
        --accept-routes
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
      export SOPS_AGE_KEY_FILE=/var/lib/sops-nix/sops_age_key.txt

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
      ${config.virtualisation.docker.package}/bin/docker compose up -d
    '';
  };

  # ---------------------------------------------------------------------------
  # Failure notification
  # ---------------------------------------------------------------------------
  # Template unit used as OnFailure= by anything whose silent failure would
  # matter. Ntfy runs locally (stacks/ntfy, bound to 127.0.0.1:10001) and
  # forwards to phone + email.
  #
  # This unit never fails itself: a notifier that can fail just produces more
  # failed units and no notification.
  systemd.services."notify-failure@" = {
    description = "Notify Ntfy that %i failed";
    serviceConfig.Type = "oneshot";
    scriptArgs = "%i";
    script = ''
      unit="$1"
      body="$(${pkgs.systemd}/bin/systemctl status --full --lines=30 "$unit" 2>&1 | head -c 3000)"
      ${pkgs.curl}/bin/curl -fsS --max-time 20 \
        -H "Title: services-vm: $unit failed" \
        -H "Priority: high" \
        -H "Tags: rotating_light" \
        -d "$body" \
        http://127.0.0.1:10001/alerts || echo "ntfy notification failed"
      exit 0
    '';
  };

  # ---------------------------------------------------------------------------
  # Backup preparation
  # ---------------------------------------------------------------------------
  # Database dumps + VPS state pull, on the host, before Backrest's window.
  # See ./backup-prepare.sh for why this is not a Backrest command hook.
  systemd.services.backup-prepare = {
    description = "Pre-backup database dumps and VPS state pull";
    after = [ "docker.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    onFailure = [ "notify-failure@%n.service" ];

    # docker must come from the configured package, not pkgs.docker — the
    # latter is 28.x, which nixpkgs marks insecure and refuses to evaluate.
    path = [ config.virtualisation.docker.package ] ++ (with pkgs; [
      sqlite
      rsync
      openssh
      coreutils
      gnugrep
      bash
    ]);

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.bash}/bin/bash ${./backup-prepare.sh}";
    };
  };

  systemd.timers.backup-prepare = {
    description = "Timer for pre-backup preparation";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # 02:45, ahead of the 03:00 fast-volume plan in stacks/backrest.
      OnCalendar = "*-*-* 02:45:00";
      Persistent = true;
      Unit = "backup-prepare.service";
    };
  };

  # Local canary: alert if backup preparation has not succeeded recently.
  # A timer that stops firing produces no failure notification by definition,
  # so something has to check for absence. The external dead-man's switch in
  # stacks/backrest covers the case where this whole host is down.
  systemd.services.backup-staleness-check = {
    description = "Alert if backup preparation has not succeeded in 48h";
    onFailure = [ "notify-failure@%n.service" ];
    serviceConfig.Type = "oneshot";
    script = ''
      stamp=/mnt/fast/_dumps/.last-success
      if [ ! -f "$stamp" ]; then
        echo "No successful backup preparation has ever been recorded."
        exit 1
      fi
      age=$(( $(date -u +%s) - $(cat "$stamp") ))
      if [ "$age" -gt 172800 ]; then
        echo "Last successful backup preparation was $(( age / 3600 ))h ago (limit 48h)."
        exit 1
      fi
      echo "Backup preparation last succeeded $(( age / 3600 ))h ago."
    '';
  };

  systemd.timers.backup-staleness-check = {
    description = "Timer for backup staleness check";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 12:00:00";
      Persistent = true;
      Unit = "backup-staleness-check.service";
    };
  };

  # Shared docker network so stacks can reach each other by service name.
  # Needed because containers cannot reach a loopback-bound host port, and all
  # published ports are now bound to 127.0.0.1 — so Backrest reaches Ntfy at
  # http://ntfy/ rather than via host.docker.internal, which does not resolve
  # on Linux and made every backup notification silently disappear.
  systemd.services.docker-network-homelab = {
    description = "Create the shared 'homelab' docker network";
    after = [ "docker.service" ];
    requires = [ "docker.service" ];
    wantedBy = [ "multi-user.target" ];
    before = [ "bootstrap-arcane.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      ${config.virtualisation.docker.package}/bin/docker network inspect homelab >/dev/null 2>&1 \
        || ${config.virtualisation.docker.package}/bin/docker network create homelab
    '';
  };

  # Holds the dedicated SSH key used to pull VPS state. Not a SOPS secret:
  # it is generated once on this host and its public half is authorised on the
  # VPS, so it never needs to travel through git.
  systemd.tmpfiles.rules = [
    "d /var/lib/backup 0700 root root -"
  ];

  # Firewall.
  #
  # Arcane's :10000 used to be open here, which exposed it to the whole trusted
  # VLAN. Arcane mounts /var/run/docker.sock, so that is a root-equivalent
  # interface with only its own login in front of it. It is now reachable over
  # the tailnet only (tailscale0 is trusted), and via Caddy.
  #
  # Note trustedInterfaces bypasses this list entirely for tailnet traffic, so
  # anything a container publishes on 0.0.0.0 is reachable from the tailnet
  # regardless of what is listed here — which is why stack compose files bind
  # published ports to 127.0.0.1 and let Caddy be the only path in.
  networking.firewall = {
    enable = true;
    trustedInterfaces = [ "tailscale0" ];
    allowedTCPPorts = [
      22    # SSH
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
