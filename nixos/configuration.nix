{ config, pkgs, lib, ... }:

let
  # Byte-identical copy of nixos-de/ssh-pubkeys.nix (the canonical one) — a
  # flake cannot reference paths outside its own root, so each flake carries
  # its own copy and the ssh-pubkey-parity lint fails the harness on drift.
  sshPubkeys = import ./ssh-pubkeys.nix;
in
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
    # The desktop's arcane-vm identity is what logs in here. Filtering nulls
    # means an ungenerated keypair grants no access rather than failing eval —
    # the ssh-pubkey-parity lint WARNs while entries are null. The test
    # suites' login key merges in via profiles.testSshAccess (list options
    # concatenate), so an empty filtered list here cannot break them.
    openssh.authorizedKeys.keys = lib.filter (k: k != null) [
      sshPubkeys.arcane-vm
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
      # Explicit, not defaulted (security review 2026-08-30 item 4): OpenSSH
      # defaults this to yes, and with UsePAM yes that opens a PAM password
      # path that PasswordAuthentication=false does not close. See the VPS
      # twin comment; the vps suite carries the mechanical assertion.
      KbdInteractiveAuthentication = false;
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

  # SOPS configuration.
  #
  # YAML, not dotenv. sops-install-secrets applies the per-secret key only for
  # yaml/json — for dotenv every /run/secrets/<name> receives the WHOLE
  # decrypted file, so `tailscale up --authkey "$(cat …)"` was handed a
  # multi-line document. Stack .sops.env files are unaffected: they are
  # consumed whole by the sops CLI in decrypt-sops-envs.service below.
  sops = {
    defaultSopsFile = ./secrets.sops.yaml;
    defaultSopsFormat = "yaml";

    age.keyFile = "/var/lib/sops-nix/sops_age_key.txt";

    secrets = {
      TAILSCALE_AUTH_KEY = { };

      # Host SSH identities (public halves: ssh-pubkeys.nix backup-vps /
      # backup-storagebox). Sops-managed so that every secret except the age
      # key itself lives encrypted in the repo — this replaces the old
      # generate-once-on-the-host ssh-keygen flow.
      #
      # A custom `path` makes sops-nix install a SYMLINK into /run/secrets.d,
      # never a regular file. That is fine here: backup-prepare.sh reads the
      # key host-side, where path resolution follows the link.
      BACKUP_VPS_SSH_KEY = {
        path = "/var/lib/backup/vps_ed25519";
        mode = "0600";
      };

      # NO custom path, on purpose: stacks/backrest mounts the whole
      # /var/lib/backup DIRECTORY into config-init (/keys:ro), and a symlink
      # to /run/secrets.d dangles inside that container's mount namespace —
      # config-init's key gate would refuse to start the stack forever. The
      # tmpfiles C+ rule below materialises a real file at the path the
      # compose file mounts instead.
      BACKUP_STORAGEBOX_SSH_KEY = {
        mode = "0600";
      };
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

      # The committed secrets.sops.yaml starts life as the encrypted template,
      # changeme_* values included — a real switch installs those verbatim and
      # this unit would register garbage against Headscale. Fail loudly with
      # the file to fix instead. Only the changeme_* template values are
      # guarded: the test fixtures' 'placeholder-replaced-at-runtime' sentinel
      # is overwritten by the suites before they start this unit.
      authkey="$(cat ${config.sops.secrets.TAILSCALE_AUTH_KEY.path})"
      case "$authkey" in changeme*)
        echo "TAILSCALE_AUTH_KEY is still a changeme_* template value — edit it with: sops nixos/secrets.sops.yaml" >&2
        exit 1 ;;
      esac

      ${pkgs.tailscale}/bin/tailscale up \
        --login-server=https://headscale.idanreed.com \
        --authkey "$authkey" \
        --hostname=services-vm \
        --accept-routes
    '';
  };

  # Decrypt all .sops.env files to .env (for arcane and stacks).
  # Uses the same age key that sops-nix uses for host secrets.
  #
  # Runs at boot AND on a minutely timer. The timer closes the gap that used
  # to be a known issue: Arcane's git sync delivers a new stack's .sops.env at
  # runtime, but a boot-only oneshot never decrypted it, so compose started
  # with unset variables instead of failing loudly — until the next reboot.
  #
  # Decryption is make-style: a .env is rewritten only when its .sops.env is
  # newer, via a tmpfile so consumers never observe a half-written .env, and
  # unchanged stacks see no mtime churn from the timer.
  systemd.services.decrypt-sops-envs = {
    description = "Decrypt .sops.env files to .env";
    after = [ "srv.mount" ];
    requires = [ "srv.mount" ];
    wantedBy = [ "multi-user.target" ];

    path = [ pkgs.sops ];

    serviceConfig = {
      Type = "oneshot";
      # NOT RemainAfterExit: starting an active unit is a no-op, so a
      # remain-after-exit oneshot would silently absorb every timer tick and
      # the runtime-sync gap would be back. bootstrap-arcane's Requires= is
      # satisfied by the successful start in the same boot transaction; it
      # does not need the unit to linger.
    };

    script = ''
      # Plaintext must never be world-readable, even transiently: /srv/stacks
      # is world-traversable, and without this the "$out.tmp" below is born
      # 0644 for the moment before its chmod.
      umask 077

      export SOPS_AGE_KEY_FILE=/var/lib/sops-nix/sops_age_key.txt

      # Per-file failures accumulate instead of aborting the walk, so one bad
      # .sops.env cannot stop every healthy stack from decrypting — and, at
      # boot, cannot leave bootstrap-arcane's Requires= forever unsatisfied
      # over a single broken stack.
      fail=0

      decrypt() {
        src="$1"
        out="$(dirname "$src")/.env"
        # Inequality in EITHER direction, not just -nt: VM restores and NTP
        # steps can move the clock backwards, leaving a "future" .env that a
        # strictly-newer check would treat as fresh forever. touch -r after a
        # successful decrypt pins out's mtime to src's, so "mtimes differ"
        # means exactly "src changed since the last successful decrypt".
        if [ ! -e "$out" ] || [ "$src" -nt "$out" ] || [ "$src" -ot "$out" ]; then
          if sops -d "$src" > "$out.tmp"; then
            mv "$out.tmp" "$out"
            touch -r "$src" "$out"
          else
            # Leave any previous .env intact; a bad new file must not take
            # down a working stack. The failure is visible in this unit's
            # journal and, via OnFailure, in ntfy.
            rm -f "$out.tmp"
            echo "FAILED to decrypt $src" >&2
            fail=1
          fi
        fi
        # OUTSIDE the freshness guard on purpose: enforced on every tick, not
        # only on re-decrypt, so root-owned .env files that predate this unit
        # on the live VM get fixed without waiting for their secret to change.
        # Idempotent and cheap. Arcane (PUID 1000) is what deploys these
        # stacks; a root-owned 0600 .env is unreadable to it and the deploy
        # fails.
        if [ -e "$out" ]; then
          chmod 600 "$out"
          chown 1000:1000 "$out"
        fi
      }

      [ -f /srv/arcane/.sops.env ] && decrypt /srv/arcane/.sops.env

      for f in /srv/stacks/*/.sops.env; do
        [ -f "$f" ] && decrypt "$f"
      done

      # Alert on state CHANGE, not on every tick. This unit runs minutely with
      # OnFailure wired to ntfy, so exiting nonzero for as long as a stack is
      # broken would be a phone push every 60s forever. The stamp survives
      # between ticks (cleared by reboot with the rest of /run): first failure
      # exits 1 and notifies, repeats stay in the journal only, and recovery
      # is logged when the stamp is removed.
      stamp=/run/decrypt-sops-envs.failed
      if [ "$fail" -ne 0 ]; then
        if [ -e "$stamp" ]; then
          echo "decryption still failing (already notified; see journal above)" >&2
          exit 0
        fi
        touch "$stamp"
        exit 1
      fi
      if [ -e "$stamp" ]; then
        rm -f "$stamp"
        echo "recovered: all .sops.env files decrypt cleanly again"
      fi
      exit 0
    '';

    onFailure = [ "notify-failure@%n.service" ];
  };

  systemd.timers.decrypt-sops-envs = {
    description = "Re-decrypt stack secrets delivered by runtime git sync";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "minutely";
      # systemd's default AccuracySec is 1min, so a "minutely" tick can land
      # up to ~120s after a .sops.env is delivered. The test suites' 150s
      # delivery waits assume prompt ticks; keep the timer honest.
      AccuracySec = "1s";
      # No Persistent: a missed tick means nothing, the next one re-scans.
      Unit = "decrypt-sops-envs.service";
    };
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

  # Holds the dedicated SSH keys, both sops-managed (see sops.secrets above):
  # vps_ed25519 arrives as a sops-nix symlink; storagebox_ed25519 must be a
  # REAL file because backrest's config-init bind-mounts this directory into
  # its container, where a /run/secrets.d symlink dangles. C+ (copy even when
  # the destination exists) runs after activation at boot and on every
  # switch, so a rotated key propagates without manual steps — and it
  # replaces any hand-generated pre-sops key left on a live host.
  systemd.tmpfiles.rules = [
    "d /var/lib/backup 0700 root root -"
    "C+ /var/lib/backup/storagebox_ed25519 0600 root root - ${config.sops.secrets.BACKUP_STORAGEBOX_SSH_KEY.path}"
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
