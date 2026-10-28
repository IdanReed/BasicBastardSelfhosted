{ config, pkgs, lib, modulesPath, ... }:

let
  sshPubkeys = import ../ssh-pubkeys.nix;
in
{
  # Hetzner Cloud is KVM: without virtio in stage 1 the boot hangs waiting for
  # the root partlabel. The VM suites cannot catch this — the test driver
  # injects its own qemu-vm profile.
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    # The cross-host secrets (OIDC client secrets, login passwords, the vlogs
    # token), read by both hosts from secrets/shared.sops.json.
    ../secrets/shared.nix
  ];

  # Identity
  networking.hostName = "headscale-vps";
  system.stateVersion = "25.11";
  time.timeZone = "UTC";

  # Boot
  # No grub.devices: disko derives them from disk-config.nix's EF02 partition,
  # and setting both trips the mirroredBoots assertion.
  boot.loader.grub.enable = true;

  # Networking
  networking = {
    useDHCP = true;
    interfaces.eth0.useDHCP = true;

    # Caddy is the only public listener; headscale (:8080) and Authentik
    # (:9000) are loopback-only behind it.
    firewall = {
      enable = true;
      allowedTCPPorts = [
        22 # SSH
        80 # Caddy — ACME HTTP-01 + redirect to HTTPS
        443 # Caddy — headscale API, embedded DERP, Authentik
      ];
      allowedUDPPorts = [
        3478 # STUN (DERP/NAT traversal)
      ];
      trustedInterfaces = [ "tailscale0" ];
    };
  };

  # Users
  users.users.idan = {
    isNormalUser = true;
    extraGroups = [ "wheel" "docker" ];
    shell = pkgs.bash;
    # null = keypair not generated yet; filtered so it grants no access rather
    # than failing eval.
    openssh.authorizedKeys.keys = lib.filter (k: k != null) [
      sshPubkeys.vps
      # `restrict` = no pty, no port/agent/X11 forwarding, no user rc. The
      # backup pull is `ssh <host> 'sudo …'` plus rsync --rsync-path, none of
      # which needs any of them; a stolen key then cannot be used as a tunnel
      # or an interactive shell. Still root via passwordless sudo below — see
      # arch-security AS-3 for the forced-command version.
      (lib.mapNullable (k: "restrict ${k}") sshPubkeys.backup-vps)
    ];
  };

  # Passwordless wheel is what makes `nixos-rebuild --use-remote-sudo` and the
  # backup pull's `sudo docker` non-interactive; an authorized key IS root.
  security.sudo.wheelNeedsPassword = false;

  # --target-host pushes unsigned store paths, which the daemon accepts only
  # from a trusted user.
  nix.settings.trusted-users = [ "root" "@wheel" ];

  # SSH
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
      # Explicit: with UsePAM yes, PasswordAuthentication=false still leaves a
      # PAM password path open.
      KbdInteractiveAuthentication = false;
    };
  };

  # Docker
  # Authentik only. Headscale is a native service so the tailnet does not
  # depend on the container runtime.
  virtualisation.docker = {
    enable = true;
    autoPrune = {
      enable = true;
      dates = "weekly";
    };
    # Log driver stays at the NixOS default (journald) — json-file log opts
    # here are fatal to dockerd.
  };

  # Journald
  # rateLimitBurst = 0 is ban evidence: journald rate-limits per sending unit
  # and dockerd submits every container line, so at the default a request
  # flood drops the authentik jail's login_failed lines silently. The byte
  # caps below are then the only bound left.
  services.journald = {
    rateLimitBurst = 0;
    storage = "persistent";
    extraConfig = ''
      SystemMaxUse=512M
      SystemKeepFree=2G
      SystemMaxFileSize=64M
    '';
  };

  # Tailscale
  services.tailscale.enable = true;

  # Packages
  environment.systemPackages = with pkgs; [
    git
    vim
    htop
    curl
    jq
    dig
    sops
    age
    # backup-prepare.sh (services VM) snapshots headscale's live WAL db with
    # `sqlite3 .backup`; a raw rsync of it can tear.
    sqlite
  ];

  # Secrets
  # yaml, not dotenv: sops-install-secrets applies the per-secret key only for
  # yaml/json — with dotenv every /run/secrets/<name> gets the whole file.
  sops = {
    defaultSopsFile = ./secrets.sops.yaml;
    defaultSopsFormat = "yaml";
    age.keyFile = "/var/lib/sops-nix/sops_age_key.txt";

    secrets = {
      TAILSCALE_AUTH_KEY = { };
    };
  };

  # Failure notification
  # Best effort: ntfy lives on the services VM behind its tailnet-only Caddy,
  # so a VPS fully off the tailnet cannot report. The out-of-band backstop is
  # the Gatus probe pair over the public internet (stacks/gatus/gatus.yaml).
  # The body is echoed to the journal first, and the notifier never fails
  # itself.
  systemd.services."notify-failure@" = {
    description = "Notify Ntfy that %i failed";
    serviceConfig.Type = "oneshot";
    scriptArgs = "%i";
    script = ''
      unit="$1"
      body="$(${pkgs.systemd}/bin/systemctl status --full --lines=30 "$unit" 2>&1 | head -c 3000)"
      echo "headscale-vps: $unit failed"
      echo "$body"
      ${pkgs.curl}/bin/curl -fsS --max-time 20 \
        -H "Title: headscale-vps: $unit failed" \
        -H "Priority: high" \
        -H "Tags: rotating_light" \
        -d "$body" \
        https://ntfy.svc.idanreed.com/alerts \
        || echo "ntfy notification failed — see the tailnet caveat in configuration.nix"
      exit 0
    '';
  };

  # Tailscale autoconnect
  # --login-server is required: without it `tailscale up --authkey` registers
  # against Tailscale's SaaS, where a headscale preauth key is not valid. This
  # host joins its own headscale, so it waits for the full public path.
  systemd.services.tailscale-autoconnect = {
    description = "Automatic connection to Headscale";
    # tailscaleD, with the d — there is no tailscale.service, and systemd
    # silently ignores ordering against a unit that does not exist.
    after = [ "network-online.target" "tailscaled.service" "headscale.service" "caddy.service" ];
    wants = [ "network-online.target" "tailscaled.service" ];
    wantedBy = [ "multi-user.target" ];

    onFailure = [ "notify-failure@%n.service" ];

    # OnFailure only fires once a unit reaches `failed`, which only happens
    # when the start limit is exceeded — unreachable at the default 5/10s with
    # RestartSec=30s. 3 attempts span ~26min < 30min, and 30min < the timer's
    # 1h gap, so a timed run is never refused as "repeated too quickly".
    startLimitIntervalSec = 1800;
    startLimitBurst = 3;

    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = "8min";
      # False so the timer's OnUnitInactiveSec fires — an active
      # RemainAfterExit oneshot never goes inactive and `start` on it is a
      # no-op.
      RemainAfterExit = false;
      # First boot races ACME issuance.
      Restart = "on-failure";
      RestartSec = "30s";
    };

    script = ''
      set -euo pipefail

      # Settle, don't sample: a timed run can land mid-restart, and treating
      # "Starting" as not-connected would re-run `up --authkey`, which fails
      # outright once a single-use preauth key is consumed.
      status=""
      for i in $(seq 1 12); do
        status="$(${pkgs.tailscale}/bin/tailscale status -json 2>/dev/null \
                  | ${pkgs.jq}/bin/jq -r .BackendState 2>/dev/null || true)"
        case "$status" in
          Running)
            echo "Already connected to Headscale"
            exit 0 ;;
          NeedsLogin|NeedsMachineAuth|Stopped)
            break ;;
        esac
        echo "tailscaled backend state '$status' ($i/12), waiting..."
        sleep 5
      done

      # Bounded wait for our own control plane, so a real misconfiguration
      # still surfaces as a unit failure.
      for i in $(seq 1 30); do
        if ${pkgs.curl}/bin/curl -fsS --max-time 5 \
             https://headscale.idanreed.com/health >/dev/null 2>&1; then
          echo "Headscale reachable"
          break
        fi
        echo "Waiting for headscale.idanreed.com ($i/30)..."
        sleep 10
      done

      # A changeme_* template value would register garbage against the
      # headscale this host fronts. Only changeme_* is guarded — the suites
      # overwrite the fixture sentinel before this unit starts.
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

  # A node that loses its registration goes to NeedsLogin and stays there, so
  # autoconnect is a repair loop rather than a boot script. OnUnitInactiveSec
  # (not OnCalendar) measures from the last stop, so runs never overlap.
  systemd.timers.tailscale-autoconnect = {
    description = "Re-check the Headscale registration hourly";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnUnitInactiveSec = "1h";
      RandomizedDelaySec = "10m";
      AccuracySec = "1m";
      Unit = "tailscale-autoconnect.service";
    };
  };

  # Host paths
  # Only Authentik needs them; headscale's state lives under its StateDirectory.
  systemd.tmpfiles.rules = [
    "d /srv/authentik 0755 root root -"
    # 70:70 = postgres-alpine's in-container uid. `d` rules re-apply ownership
    # on every activation, so root:root here re-owns live PGDATA out from
    # under postgres.
    "d /srv/authentik/pgdata 0700 70 70 -"
    "d /srv/authentik/media 0755 root root -"
    "d /srv/authentik/certs 0755 root root -"
    "d /srv/authentik/templates 0755 root root -"
    "d /var/lib/sops-nix 0700 root root -"
  ];

  # Fail2ban
  # Layer 1 of the login-hardening pair; layer 2 is
  # authentik/blueprints/custom/login-hardening.yaml, whose reputation policy
  # scores per (username, ip) and so catches IP rotation. maxretry/bantime
  # below land in [DEFAULT] and cover both jails.
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
        };
      };

      # backend=systemd reads the journal (the server container logs there by
      # CONTAINER_TAG, authentik/compose.yaml). The filter extracts authentik's
      # FORWARDED client_ip, never the TCP peer — that is always Caddy on
      # loopback, and banning it bricks the proxy for everyone. findtime is
      # widened to 1h so failures spread across minutes still accumulate.
      authentik = {
        settings = {
          enabled = true;
          backend = "systemd";
          filter = "authentik";
          journalmatch = "CONTAINER_TAG=authentik-server";
          findtime = "1h";
        };
      };
    };
  };

  # A sibling environment.etc file rather than the jail's `filter` option: the
  # module's INI generator mangles this file's comments. filter.d is a glob, so
  # siblings coexist. The regex was captured empirically against
  # ghcr.io/goauthentik/server:2026.8.5; tests/suites/vps.nix re-runs
  # fail2ban-regex over that sample plus negative controls.
  environment.etc."fail2ban/filter.d/authentik.conf".text = ''
    # authentik login_failed brute-force filter.
    #
    # The lookahead gates on the login_failed action anywhere on the line and
    # the consume captures client_ip anywhere on it, so both survive JSON key
    # reordering. Gating on exactly "login_failed" is deliberate: the
    # successful-login "login" event and the identification "invalid_login"
    # event also carry client_ip, and neither should ban.
    [Definition]
    failregex = ^(?=.*?"action"\s*:\s*"login_failed").*?"client_ip"\s*:\s*"<HOST>"
    journalmatch = CONTAINER_TAG=authentik-server
  '';

  # The module restarts the daemon only when its OWN configs change, so an
  # edit to the filter above would deploy the file and leave the daemon on the
  # old regex.
  systemd.services.fail2ban.restartTriggers = [
    config.environment.etc."fail2ban/filter.d/authentik.conf".source
  ];

  # Nix
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
