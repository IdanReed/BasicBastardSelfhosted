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

    # journald driver (NixOS logDriver default) owns rotation; json-file opts
    # here are FATAL to dockerd ("unknown log opt 'max-file'", sweep-caught).
  };

  # ---------------------------------------------------------------------------
  # journald
  # ---------------------------------------------------------------------------
  # 🚨 rateLimitBurst = 0 IS BAN EVIDENCE, not tidiness. fail2ban's authentik
  # jail (below) is backend=systemd: it reads login_failed lines out of the
  # journal. journald rate-limits PER SENDING UNIT and docker's journald driver
  # submits every container line from dockerd itself, so the authentik server
  # container shares ONE bucket with anything else that driver carries. At the
  # systemd default (10000 messages / 30 s) a public request flood to
  # auth.idanreed.com — authentik logs at least one info line per request, so
  # ~333 rps is enough — exhausts the window, and interleaved brute-force
  # login_failed lines never reach fail2ban at all. Measured on the services VM
  # at the default burst: 20006 of 30000 lines gone, with no "Suppressed N
  # messages" note to say so. Setting burst or interval to 0 disables rate
  # limiting entirely (journald.conf(5)).
  services.journald = {
    rateLimitBurst = 0;

    # Explicit, not defaulted: with the rate limit off, the byte cap is the only
    # bound left, and a silent upstream default change would remove it.
    storage = "persistent";

    extraConfig = ''
      # The trade the line above buys: a flood now rotates journal history
      # faster instead of dropping lines silently. Sized for that. This is a
      # single-partition host (disk-config.nix: one ext4 root filling the disk),
      # so both caps protect the filesystem the control plane lives on.
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
    # Consumed by the services VM's backup-prepare.sh over ssh: it snapshots
    # headscale's live WAL-mode db.sqlite with `sqlite3 ... ".backup"` before
    # pulling it. A raw rsync of a live WAL database can land a torn copy.
    sqlite
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

  # ---------------------------------------------------------------------------
  # Failure notification
  # ---------------------------------------------------------------------------
  # Template unit used as OnFailure= by the units on this host whose silent
  # failure matters: headscale, caddy, authentik, tailscale-autoconnect. Until
  # this landed the VPS had OnFailure on nothing at all — a dead control plane
  # said nothing to anyone.
  #
  # 🚨 READ THIS BEFORE TRUSTING IT. Delivery is BEST EFFORT AND PARTLY
  # SELF-REFERENTIAL, and there is no way around that without building
  # infrastructure this fleet has deliberately not built:
  #
  #   - ntfy runs on the SERVICES VM (stacks/ntfy), published on
  #     127.0.0.1:10001 and reachable only through that host's Caddy, which
  #     binds the tailnet IP. ntfy.svc.idanreed.com is a public Cloudflare A
  #     record pointing into 100.64.0.0/10, so the name resolves from
  #     anywhere but only routes from inside the tailnet. There is no public
  #     ntfy endpoint to fall back to.
  #   - Therefore: an alert about headscale or tailscale-autoconnect travels
  #     over the very tailnet whose coordination server just failed. In
  #     practice established WireGuard sessions survive a headscale outage
  #     (headscale is the control plane, not the data plane) so the alert
  #     usually still gets out — but "usually" is the honest word, and a
  #     VPS that has fully left the tailnet CANNOT report anything.
  #
  # The out-of-band backstop is deliberately somewhere else and is the reason
  # this is acceptable: stacks/gatus/gatus.yaml runs on the services VM and
  # probes https://headscale.idanreed.com/health and
  # https://auth.idanreed.com/-/health/ready/ over the PUBLIC internet, then
  # alerts through ntfy's loopback address. That path shares nothing with the
  # tailnet, so it is what actually catches "the VPS is gone".
  #
  # The body is echoed to the journal before the publish, so `journalctl -u
  # notify-failure@...` is a local record even when nothing was delivered.
  # This unit never fails itself: a notifier that can fail just produces more
  # failed units and no notification.
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
  # It is also NOT boot-only. See the timer below.
  systemd.services.tailscale-autoconnect = {
    description = "Automatic connection to Headscale";
    # tailscaleD, with the d. `services.tailscale.enable` creates
    # tailscaled.service and there is no tailscale.service — systemd silently
    # ignores an ordering dependency on a unit that does not exist, so the
    # previous "tailscale.service" here bought nothing and this unit could
    # start before the daemon it talks to. Harmless before, because the script
    # slept 2s and had one shot; now that it re-runs on a timer it matters,
    # and the settle loop below is the belt to this braces.
    # (The twin unit in nixos/configuration.nix carries the same fix.)
    after = [ "network-online.target" "tailscaled.service" "headscale.service" "caddy.service" ];
    wants = [ "network-online.target" "tailscaled.service" ];
    wantedBy = [ "multi-user.target" ];

    onFailure = [ "notify-failure@%n.service" ];

    # Without these, OnFailure above could never fire: systemd reaches the
    # `failed` state only when the start-rate limit is exceeded, and the
    # defaults (5 starts / 10 SECONDS) can never be hit by a unit whose
    # RestartSec is 30s. The unit would retry every 30s forever, always
    # "activating", never failed, and the notifier would never run — a
    # permanently-off-tailnet host reporting nothing.
    #
    # The three numbers here (8min cap per attempt, 3 attempts, 30min window)
    # are sized against each other and against the timer below:
    #   - the script's own bounded waits are 60s + 300s, so TimeoutStartSec
    #     8min bounds an attempt without ever cutting a legitimate one short;
    #   - 3 attempts therefore span at most ~26min, comfortably inside the
    #     30min window, so the limit is genuinely reached and the unit really
    #     does enter `failed` rather than looping forever;
    #   - 30min is well under the timer's 1h minimum gap, so the next timed
    #     run is never refused with "start request repeated too quickly".
    # Giving up is not permanent: the timer below starts it again every hour.
    startLimitIntervalSec = 1800;
    startLimitBurst = 3;

    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = "8min";

      # RemainAfterExit is deliberately FALSE, which is a change: with it true
      # the unit stays `active` forever after the first success, and a unit
      # that is never inactive can never satisfy OnUnitInactiveSec — the timer
      # below would be installed and would never fire. (OnUnitActiveSec is not
      # a fix either: it would fire, but `systemctl start` on an already-active
      # RemainAfterExit oneshot is a no-op, so the run would do nothing.)
      # Nothing orders itself after this unit, so losing the latched active
      # state costs nothing.
      RemainAfterExit = false;

      # First boot races ACME issuance, which can take a minute or two.
      # Retry rather than leaving the host off its own tailnet until someone
      # notices and reruns this by hand.
      Restart = "on-failure";
      RestartSec = "30s";
    };

    script = ''
      set -euo pipefail

      # Settle before deciding, rather than sampling once after a fixed sleep.
      # This runs repeatedly now (timer below), so it can land while tailscaled
      # is mid-restart and reporting "Starting" — and treating "Starting" as
      # "not connected" would push an already-registered node through
      # `tailscale up --authkey` again, which fails outright if the preauth key
      # was single-use and has been consumed. Wait for a terminal state
      # instead. `|| true` because tailscaled may not be answering yet at all.
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

  # The re-run that makes tailscale-autoconnect a repair loop instead of a
  # one-shot boot script.
  #
  # The failure it exists for: a node that loses its registration — key expiry
  # (see the long oidc.expiry comment in modules/headscale.nix), a control
  # plane rebuilt from an old backup, a node deleted by mistake — goes to
  # NeedsLogin and STAYS there. The old unit ran once at boot with
  # RemainAfterExit=true and never ran again, so recovery required a human to
  # notice and a reboot or a manual `systemctl start`. On a headless VPS
  # whose alerting runs over the tailnet it just lost, that human notices
  # late.
  #
  # OnUnitInactiveSec, not OnCalendar/OnBootSec: it measures from when the
  # service last STOPPED, so a run that takes five minutes does not shorten
  # the next gap, and the service and its timer cannot overlap. This is the
  # half that required RemainAfterExit=false above — a unit that never goes
  # inactive never triggers it.
  #
  # Hourly with a 10-minute jitter. The script is a no-op costing one
  # `tailscale status` call when the node is already Running (it exits before
  # touching the network or the authkey), so the cost of hourly is nil, and
  # an hour is the worst-case recovery latency for a node that fell off. A
  # PERSISTENTLY broken autoconnect will therefore alert about once an hour —
  # that is intended, not fatigue: it means this host is off the tailnet.
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
