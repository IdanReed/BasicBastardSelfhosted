{ config, pkgs, lib, ... }:

let
  # Byte-identical copy of nixos-de/ssh-pubkeys.nix (the canonical one) — a
  # flake cannot reference paths outside its own root, so each flake carries
  # its own copy and the ssh-pubkey-parity lint fails the harness on drift.
  sshPubkeys = import ./ssh-pubkeys.nix;
in
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
    # Two identities log in here: the desktop (vps) and the services VM's
    # backup-vps key, which backup-prepare.sh uses for the nightly state pull
    # (ssh + sudo docker pg_dumpall + rsync of /var/lib/headscale). Filtering
    # nulls means an ungenerated keypair grants no access rather than failing
    # eval — the ssh-pubkey-parity lint WARNs while entries are null. The
    # test suites' login key merges in via profiles.testSshAccess (list
    # options concatenate), so an empty filtered list here cannot break them.
    openssh.authorizedKeys.keys = lib.filter (k: k != null) [
      sshPubkeys.vps
      sshPubkeys.backup-vps
    ];
  };

  # Allow passwordless sudo for wheel group
  # Deliberate trade (security review 2026-08-30, lower-priority item):
  # passwordless wheel is what makes `nixos-rebuild switch --target-host
  # ... --use-remote-sudo` and the backup pull's `sudo docker` work
  # non-interactively. The cost is stated plainly: compromise of an
  # authorized SSH key IS instant root on this host. The mitigations are
  # upstream of sudo — key-only auth, KbdInteractive off, fail2ban, and
  # the keys themselves living sops-encrypted rather than loose.
  security.sudo.wheelNeedsPassword = false;

  # SSH server
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
      # Explicit, not defaulted (security review 2026-08-30 item 4): OpenSSH's
      # own default is yes, and with UsePAM yes (the NixOS default) that opens
      # a PAM password path that PasswordAuthentication=false does not close.
      # Inert only while every account is password-locked — load-bearing by
      # accident until this line. The vps suite forces the method on and
      # asserts refusal.
      KbdInteractiveAuthentication = false;
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

  # Fail2ban: SSH plus Authentik's login page — the two public brute-force
  # surfaces. SSH is the deliberately-public port 22; Authentik's login lives
  # behind Caddy on :443 (auth.idanreed.com). This is layer 1 of the
  # login-hardening pair; layer 2 is the reputation-policy blueprint at
  # authentik/blueprints/custom/login-hardening.yaml. The two are
  # complementary: fail2ban bans the source IP at the firewall after a few
  # failures in a window; the reputation policy scores per (username, ip) and
  # so denies even an attacker rotating source IPs.
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

      # Authentik login brute-force. backend=systemd reads the journal (the
      # server container logs there via the journald driver + CONTAINER_TAG,
      # set in authentik/compose.yaml); the filter extracts authentik's
      # FORWARDED client_ip, never the TCP peer. The peer is always Caddy on
      # loopback — banning it would brick the reverse proxy for everyone.
      # maxretry/bantime mirror sshd; findtime is widened to 1h (default 10m)
      # so failures spread across minutes still accumulate toward a ban.
      authentik = {
        settings = {
          enabled = true;
          backend = "systemd";
          filter = "authentik";
          journalmatch = "CONTAINER_TAG=authentik-server";
          maxretry = 3;
          findtime = "1h";
          bantime = "1h";
        };
      };
    };
  };

  # The module does offer per-jail `jails.<name>.filter`, but its INI
  # generator would mangle the long verbatim sample-line comment below — and
  # that comment IS the provenance for the regex — so the filter ships as a
  # sibling environment.etc file instead (the module's filter.d entry is a
  # `/*.conf` glob, so siblings coexist). The failregex was captured
  # EMPIRICALLY (see the sample line and image version in the file) and
  # validated with fail2ban-regex; the vps suite re-runs that check plus
  # negative controls so the filter can drift neither under nor over.
  environment.etc."fail2ban/filter.d/authentik.conf".text = ''
    # authentik login_failed brute-force filter.
    #
    # Sample line captured VERBATIM by driving a failed flow login against the
    # pinned image ghcr.io/goauthentik/server:2026.5.6 (server container,
    # journald driver, X-Forwarded-For spoofed to stand in for Caddy):
    #
    # {"action": "login_failed", "auth_via": "unauthenticated", "client_ip": "203.0.113.77", "context": {"http_request": {"args": {}, "method": "POST", "path": "/api/v3/flows/executor/default-authentication-flow/", "request_id": "dd8c847ae65f4bd8b8f9b4a22c087385", "user_agent": "curl/8.19.0"}, "password": "********************", "stage": {"app": "authentik_stages_password", "model_name": "passwordstage", "name": "default-authentication-password", "pk": "c0ad2df11f11428a8ca68c73980bd067"}, "username": "akadmin"}, "domain_url": "127.0.0.1", "event": "Created Event", "host": "127.0.0.1:19000", "level": "info", "logger": "authentik.events.models", "pid": 184, "request_id": "dd8c847ae65f4bd8b8f9b4a22c087385", "schema_name": "public", "timestamp": "2026-08-30T19:25:26.527644", "user": {"email": "admin@idanreed.com", "pk": 4, "username": "akadmin"}}
    #
    # The lookahead gates on the login_failed action anywhere on the line and
    # the consume captures client_ip anywhere on the line, so the two survive
    # any JSON key reordering. client_ip is authentik's FORWARDED client
    # address (the TCP source it sees is loopback from Caddy). Gating on
    # exactly "login_failed" is deliberate: the successful-login "login" event
    # and the identification "invalid_login" event also carry client_ip, and
    # neither should ban.
    [Definition]
    failregex = ^(?=.*?"action"\s*:\s*"login_failed").*?"client_ip"\s*:\s*"<HOST>"
    journalmatch = CONTAINER_TAG=authentik-server
  '';

  # The pinned NixOS fail2ban module restarts the daemon only when its OWN
  # generated configs change (fail2banConf/jailConf/pathsConf) — an edit to
  # the environment.etc filter above deploys the new file but leaves the
  # running daemon on the old regex until something else restarts it. Tie the
  # restart to the filter content explicitly.
  systemd.services.fail2ban.restartTriggers = [
    config.environment.etc."fail2ban/filter.d/authentik.conf".source
  ];

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
