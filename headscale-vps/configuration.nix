{ config, pkgs, lib, ... }:

let
  # Byte-identical copy of nixos-de/ssh-pubkeys.nix (canonical) — see its
  # header; the ssh-pubkey-parity lint fails on drift.
  sshPubkeys = import ./ssh-pubkeys.nix;
in
{
  # System identity
  networking.hostName = "headscale-vps";
  system.stateVersion = "25.11";
  time.timeZone = "UTC";

  # Hetzner legacy MBR boot. Install device deliberately NOT set: disko
  # derives boot.loader.grub.devices from disk-config.nix's EF02 partition;
  # setting it too trips the "duplicated devices in mirroredBoots" assertion.
  boot.loader.grub.enable = true;

  # Networking (Hetzner DHCP)
  networking = {
    useDHCP = true;
    interfaces.eth0.useDHCP = true;

    firewall = {
      enable = true;
      # Caddy is the only public listener (modules/caddy.nix); headscale
      # (loopback:8080) and Authentik (loopback:9000) sit behind it. Do not
      # reopen 9000/9443 — that exposed Authentik's admin over plain HTTP.
      allowedTCPPorts = [
        22    # SSH
        80    # Caddy - ACME HTTP-01 challenge + redirect to HTTPS
        443   # Caddy - Headscale API, embedded DERP, Authentik
      ];
      allowedUDPPorts = [
        3478  # STUN (DERP/NAT traversal)
      ];
      trustedInterfaces = [ "tailscale0" ];
    };
  };

  # User configuration
  users.users.idan = {
    isNormalUser = true;
    extraGroups = [ "wheel" "docker" ];
    shell = pkgs.bash;
    # vps (desktop) + backup-vps (services VM's nightly state pull via
    # backup-prepare.sh). Null-filtering: an ungenerated keypair grants no
    # access rather than failing eval (parity lint WARNs). The test suites'
    # login key merges in via profiles.testSshAccess, so an empty filtered
    # list cannot break them.
    openssh.authorizedKeys.keys = lib.filter (k: k != null) [
      sshPubkeys.vps
      sshPubkeys.backup-vps
    ];
  };

  # Deliberate trade (security review 2026-08-30): passwordless wheel is what
  # lets `nixos-rebuild switch --target-host --use-remote-sudo` and the backup
  # pull's `sudo docker` run non-interactively — compromise of an authorized
  # SSH key IS instant root. Mitigations are upstream of sudo: key-only auth,
  # KbdInteractive off, fail2ban, sops-encrypted keys.
  security.sudo.wheelNeedsPassword = false;

  # SSH server
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
      # Explicit, not defaulted (security review 2026-08-30 item 4): OpenSSH
      # defaults yes, and with UsePAM yes (NixOS default) that opens a PAM
      # password path PasswordAuthentication=false does not close. The vps
      # suite forces the method on and asserts refusal.
      KbdInteractiveAuthentication = false;
    };
  };

  # Docker for Authentik only. Headscale runs as a native systemd service
  # (modules/headscale.nix) so that the tailnet does not depend on the
  # container runtime being healthy.
  virtualisation.docker = {
    enable = true;
    # 25.11's default `docker` is 28.x, marked insecure by nixpkgs
    # ("unmaintained since November 2025").
    package = pkgs.docker_29;
    autoPrune = {
      enable = true;
      dates = "weekly";
    };

    # journald driver (NixOS logDriver default) owns rotation; json-file opts
    # here are FATAL to dockerd ("unknown log opt 'max-file'").
  };

  # ---------------------------------------------------------------------------
  # journald
  # ---------------------------------------------------------------------------
  # 🚨 rateLimitBurst = 0 IS BAN EVIDENCE. The fail2ban authentik jail is
  # backend=systemd; journald rate-limits PER SENDING UNIT, and docker's
  # journald driver submits every container line from dockerd, so authentik
  # shares ONE bucket with everything else the driver carries. At the default
  # (10000 messages / 30s) a request flood — authentik logs ≥1 info line per
  # request, so ~333 rps suffices — drowns interleaved login_failed lines
  # before fail2ban sees them. Measured at the default burst: 20006 of 30000
  # lines gone, with no "Suppressed N messages" note. 0 disables rate
  # limiting entirely (journald.conf(5)).
  services.journald = {
    rateLimitBurst = 0;

    # Explicit: with the rate limit off, the byte cap is the only bound left;
    # a silent upstream default change would remove it.
    storage = "persistent";

    extraConfig = ''
      # The trade rateLimitBurst=0 buys: a flood rotates history faster
      # instead of dropping lines silently. Single-partition host (one ext4
      # root), so these caps protect the control plane's own filesystem.
      SystemMaxUse=512M
      SystemKeepFree=2G
      SystemMaxFileSize=64M
    '';
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
    # backup-prepare.sh (services VM) snapshots headscale's live WAL db over
    # ssh with `sqlite3 .backup` — a raw rsync of a live WAL db can tear.
    sqlite
  ];

  # SOPS: YAML, not dotenv — sops-install-secrets applies the per-secret key
  # only for yaml/json; with dotenv it silently copies the WHOLE decrypted
  # file into every /run/secrets/<name>. Shipped once (headscale got a
  # multi-line doc as its OIDC secret); the sops-dotenv-extraction lint
  # guards the format.
  sops = {
    defaultSopsFile = ./secrets.sops.yaml;
    defaultSopsFormat = "yaml";
    age.keyFile = "/var/lib/sops-nix/sops_age_key.txt";

    secrets = {
      TAILSCALE_AUTH_KEY = { };
    };
  };

  # ---------------------------------------------------------------------------
  # Failure notification
  # ---------------------------------------------------------------------------
  # OnFailure= template for the units whose silent failure matters:
  # headscale, caddy, authentik, tailscale-autoconnect.
  #
  # 🚨 Delivery is BEST EFFORT AND PARTLY SELF-REFERENTIAL: ntfy runs on the
  # services VM behind its tailnet-only Caddy (ntfy.svc.idanreed.com resolves
  # publicly but routes only inside the tailnet; no public fallback), so an
  # alert about headscale travels over the very tailnet whose control plane
  # just failed. Established WireGuard sessions usually survive (headscale is
  # control plane, not data plane) — but a VPS fully off the tailnet CANNOT
  # report. The out-of-band backstop is stacks/gatus/gatus.yaml probing both
  # public names from the services VM over the PUBLIC internet; that is what
  # actually catches "the VPS is gone".
  #
  # The body is echoed to the journal before the publish (local record even
  # when undelivered), and the unit never fails itself — a failing notifier
  # is just more failed units and no notification.
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

  # Tailscale auto-login.
  #
  # --login-server is REQUIRED: without it `tailscale up --authkey` registers
  # against Tailscale's SaaS, where a Headscale-issued preauth key is not
  # valid — the node silently fails to join the tailnet this host serves.
  # This host joins its own Headscale, so it waits for the full public path
  # (headscale on loopback + Caddy holding a valid cert). NOT boot-only —
  # see the timer below.
  systemd.services.tailscale-autoconnect = {
    description = "Automatic connection to Headscale";
    # tailscaleD, with the d: there is no tailscale.service, and systemd
    # silently ignores ordering on a unit that does not exist — the settle
    # loop below is the belt to this braces. (Twin unit in
    # nixos/configuration.nix.)
    after = [ "network-online.target" "tailscaled.service" "headscale.service" "caddy.service" ];
    wants = [ "network-online.target" "tailscaled.service" ];
    wantedBy = [ "multi-user.target" ];

    onFailure = [ "notify-failure@%n.service" ];

    # Without these OnFailure could never fire: `failed` is only reached when
    # the start-rate limit is exceeded, and the default (5 starts / 10
    # SECONDS) is unreachable with RestartSec=30s — forever "activating",
    # never failed, notifier never runs. The numbers are sized against each
    # other and the timer: the script's bounded waits are 60s + 300s, so
    # TimeoutStartSec 8min never cuts a legitimate attempt short; 3 attempts
    # span ~26min < the 30min window, so the limit IS genuinely reached; and
    # 30min < the timer's 1h gap, so a timed run is never refused with "start
    # request repeated too quickly". Giving up is not permanent: the timer
    # restarts it hourly.
    startLimitIntervalSec = 1800;
    startLimitBurst = 3;

    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = "8min";

      # Deliberately FALSE: with true the unit stays `active` forever and
      # OnUnitInactiveSec never fires (OnUnitActiveSec is no fix — `start` on
      # an active RemainAfterExit oneshot is a no-op). Nothing orders itself
      # after this unit, so the latched state costs nothing to lose.
      RemainAfterExit = false;

      # First boot races ACME issuance (a minute or two); retry rather than
      # staying off the tailnet until a human notices.
      Restart = "on-failure";
      RestartSec = "30s";
    };

    script = ''
      set -euo pipefail

      # Settle, don't sample: timed runs can land while tailscaled is
      # mid-restart reporting "Starting", and treating that as "not connected"
      # would re-run `up --authkey` — which fails outright if the preauth key
      # was single-use and consumed. Wait for a terminal state. `|| true`
      # because tailscaled may not be answering at all yet.
      status=""
      for i in $(seq 1 12); do
        status="$(${pkgs.tailscale}/bin/tailscale status -json 2>/dev/null \
                  | ${pkgs.jq}/bin/jq -r .BackendState 2>/dev/null || true)"
        case "$status" in
          Running)
            echo "Already connected to Headscale"
            exit 0 ;;
          NeedsLogin|NeedsMachineAuth|Stopped)
            # Terminal: no amount of waiting fixes these, go register.
            break ;;
        esac
        echo "tailscaled backend state '$status' ($i/12), waiting..."
        sleep 5
      done

      # Bounded wait for our own control plane over HTTPS — a genuine
      # misconfiguration still surfaces as a unit failure.
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
      # Headscale this host fronts — fail loudly with the file to fix. Only
      # changeme_* is guarded: the test fixtures' sentinel is overwritten by
      # the suites before this unit starts.
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

  # The re-run that makes autoconnect a repair loop, not a boot script: a
  # node that loses its registration — key expiry (see oidc.expiry in
  # modules/headscale.nix), a control plane restored from an old backup, a
  # node deleted by mistake — goes to NeedsLogin and STAYS there.
  #
  # OnUnitInactiveSec, not OnCalendar/OnBootSec: measured from when the
  # service last STOPPED, so runs never overlap — the half that required
  # RemainAfterExit=false above. Hourly + 10min jitter: the already-Running
  # case exits after one `tailscale status` call, so hourly is free, and an
  # hour is the worst-case recovery latency. A PERSISTENTLY broken
  # autoconnect therefore alerts about hourly — intended, not fatigue: it
  # means this host is off the tailnet.
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

  # Only Authentik needs host paths — Headscale's state lives under its own
  # StateDirectory.
  systemd.tmpfiles.rules = [
    "d /srv/authentik 0755 root root -"
    "d /srv/authentik/pgdata 0700 root root -"
    "d /srv/authentik/redis 0755 root root -"
    "d /srv/authentik/media 0755 root root -"
    "d /srv/authentik/certs 0755 root root -"
    "d /srv/authentik/templates 0755 root root -"
    "d /var/lib/sops-nix 0700 root root -"
  ];

  # Fail2ban: SSH + Authentik's login page, the two public brute-force
  # surfaces. Layer 1 of the login-hardening pair — layer 2 is
  # authentik/blueprints/custom/login-hardening.yaml, whose reputation policy
  # scores per (username, ip) and so catches attackers rotating source IPs,
  # which an IP ban cannot.
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

      # backend=systemd reads the journal (server container logs there via
      # journald driver + CONTAINER_TAG, authentik/compose.yaml); the filter
      # extracts authentik's FORWARDED client_ip, never the TCP peer — the
      # peer is always Caddy on loopback, and banning it bricks the proxy for
      # everyone. findtime widened to 1h (default 10m) so failures spread
      # across minutes still accumulate.
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

  # Sibling environment.etc file, not the module's per-jail `filter`: the
  # module's INI generator would mangle the verbatim sample-line comment
  # below, which IS the regex's provenance (the filter.d entry is a `/*.conf`
  # glob, so siblings coexist). Captured EMPIRICALLY and validated with
  # fail2ban-regex; the vps suite re-runs that check plus negative controls.
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

  # The fail2ban module restarts the daemon only when its OWN generated
  # configs change — an edit to the environment.etc filter above would deploy
  # the file but leave the running daemon on the old regex. Tie the restart
  # to the filter content.
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
