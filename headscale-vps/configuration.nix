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
      # Caddy is the only public listener (modules/caddy.nix). Headscale sits on
      # loopback:8080 and Authentik on loopback:9000 behind it; neither is
      # published directly any more. 9000/9443 were previously open, which
      # exposed Authentik's admin interface over plain HTTP to the internet.
      allowedTCPPorts = [
        22    # SSH
        80    # Caddy - ACME HTTP-01 challenge + redirect to HTTPS
        443   # Caddy - Headscale API, embedded DERP, Authentik
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

  # SOPS configuration.
  #
  # YAML, not dotenv. sops-install-secrets applies the per-secret key only for
  # yaml/json — for dotenv it copies the WHOLE decrypted file into every
  # /run/secrets/<name> (dotenv is handled exactly like binary, and nothing
  # warns). With the old .sops.env, headscale got a multi-line document as its
  # OIDC client secret and tailscale an unusable auth key. Caught by
  # tests/lib/lints.nix (sops-dotenv-extraction), which now guards the format.
  sops = {
    defaultSopsFile = ./secrets.sops.yaml;
    defaultSopsFormat = "yaml";
    age.keyFile = "/var/lib/sops-nix/sops_age_key.txt";

    secrets = {
      TAILSCALE_AUTH_KEY = { };
    };
  };

  # Tailscale auto-login service.
  #
  # --login-server is REQUIRED. Without it `tailscale up --authkey` registers
  # against Tailscale's SaaS control plane, where a Headscale-issued preauth
  # key (see .sops.env.example) is not valid — the node would silently fail to
  # join the tailnet this host is itself serving.
  #
  # This host joins its own Headscale, so it must wait for the full public
  # path to be up: headscale on loopback, and Caddy holding a valid
  # certificate for headscale.idanreed.com.
  systemd.services.tailscale-autoconnect = {
    description = "Automatic connection to Headscale";
    after = [ "network-online.target" "tailscale.service" "headscale.service" "caddy.service" ];
    wants = [ "network-online.target" "tailscale.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # First boot races ACME issuance, which can take a minute or two.
      # Retry rather than leaving the host off its own tailnet until someone
      # notices and reruns this by hand.
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

      # Wait for our own control plane to answer over HTTPS. Bounded, so a
      # genuine misconfiguration still surfaces as a unit failure.
      for i in $(seq 1 30); do
        if ${pkgs.curl}/bin/curl -fsS --max-time 5 \
             https://headscale.idanreed.com/health >/dev/null 2>&1; then
          echo "Headscale reachable"
          break
        fi
        echo "Waiting for headscale.idanreed.com ($i/30)..."
        sleep 10
      done

      # The committed secrets.sops.yaml starts life as the encrypted template,
      # changeme_* values included — a real switch installs those verbatim and
      # this unit would register garbage against the Headscale it fronts. Fail
      # loudly with the file to fix instead. Only the changeme_* template
      # values are guarded: the test fixtures' 'placeholder-replaced-at-runtime'
      # sentinel is overwritten by the suites before they start this unit.
      authkey="$(cat ${config.sops.secrets.TAILSCALE_AUTH_KEY.path})"
      case "$authkey" in changeme*)
        echo "TAILSCALE_AUTH_KEY is still a changeme_* template value — edit it with: sops headscale-vps/secrets.sops.yaml" >&2
        exit 1 ;;
      esac

      ${pkgs.tailscale}/bin/tailscale up \
        --login-server=https://headscale.idanreed.com \
        --authkey "$authkey" \
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
