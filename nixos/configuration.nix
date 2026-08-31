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
  #
  # 🚨 NOT RemainAfterExit, and that is the whole point of the timer below.
  # This unit used to be a boot-only `RemainAfterExit = true` oneshot, which
  # made it a SCHEDULED FAILURE: Headscale's default node expiry is 180 days,
  # and at day 180 this VM's node key expires, the node drops off the tailnet,
  # and nothing ever runs `tailscale up` again — the unit is still sitting in
  # `active (exited)` from the boot six months earlier. Two systemd behaviours
  # made it unfixable in place, and both are already documented one unit down
  # on decrypt-sops-envs:
  #
  #   - `systemctl start` on an ALREADY-ACTIVE RemainAfterExit oneshot is a
  #     no-op, so a timer pointed at it would fire and do nothing forever.
  #   - OnUnitInactiveSec= measures from the last deactivation, and a unit
  #     that never deactivates never provides one, so the timer would never
  #     elapse in the first place.
  #
  # Dropping RemainAfterExit costs nothing: nothing orders itself After= this
  # unit, and the boot transaction is satisfied by the oneshot completing, not
  # by it lingering.
  systemd.services.tailscale-autoconnect = {
    description = "Automatic connection to Headscale";
    after = [ "network-online.target" "tailscale.service" ];
    wants = [ "network-online.target" "tailscale.service" ];
    wantedBy = [ "multi-user.target" ];

    # The tailnet going away takes the SSH path to this host with it, so a
    # human finds out by trying to log in. Ntfy is loopback-local
    # (127.0.0.1:10001) and does not ride the tailnet, so this notification
    # still leaves the box even when the thing that failed is the tailnet.
    onFailure = [ "notify-failure@%n.service" ];

    # Bounds the retry loop below so it can actually reach the `failed` state.
    # Restart=on-failure with RestartSec=30s and systemd's default limiter
    # (5 starts per 10s) can NEVER trip — 30s spacing means the window always
    # resets — so the unit would retry silently forever and OnFailure= would be
    # dead code. 20 attempts over ~10 minutes is long enough for a VPS that is
    # still booting, and then it gives up loudly and lets the timer retry.
    unitConfig = {
      StartLimitIntervalSec = "30min";
      StartLimitBurst = 20;
    };

    serviceConfig = {
      Type = "oneshot";
      # The VPS may still be booting or reissuing certificates. Retry rather
      # than sitting off the tailnet until someone reruns this by hand.
      Restart = "on-failure";
      RestartSec = "30s";
    };

    script = ''
      set -euo pipefail

      # Wait for tailscaled to be ready
      sleep 2

      # Check if already authenticated.
      #
      # This early exit is what makes the periodic re-run safe: while the node
      # is up, the timer's job is to do NOTHING. Re-running `tailscale up`
      # against a healthy connection would reapply preferences and churn the
      # session for no reason, and (worse) burn a single-use Headscale preauth
      # key on a node that did not need one.
      #
      # It is also why the re-run can repair the day-180 case: an expired node
      # key leaves BackendState at NeedsLogin, not Running, so the next tick
      # falls through to `tailscale up` and re-registers. If the stored preauth
      # key is itself spent or expired, that fails — loudly, through OnFailure
      # above, which is the correct outcome: nothing automatic can fix it and a
      # human has to mint a new key on the VPS.
      status="$(${pkgs.tailscale}/bin/tailscale status -json | ${pkgs.jq}/bin/jq -r .BackendState)"
      if [ "$status" = "Running" ]; then
        # Report the node key's expiry on every tick, so the journal answers
        # "how long has this got left" without a trip to the VPS. "none" means
        # Headscale set no expiry for this node. Never allowed to fail the
        # unit: this is a log line, and `set -e` would otherwise turn a
        # perfectly healthy connection into a failed unit over a jq hiccup.
        expiry="$(${pkgs.tailscale}/bin/tailscale status -json \
          | ${pkgs.jq}/bin/jq -r '.Self.KeyExpiry // "none"' 2>/dev/null || echo unknown)"
        echo "Already connected to Headscale (node key expiry: $expiry)"
        exit 0
      fi
      echo "Not connected (BackendState=$status) - registering against Headscale"

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

  # Re-run tailscale-autoconnect periodically. See the 🚨 block on the unit for
  # why it exists at all; this is the half that makes the day-180 node-key
  # expiry self-heal instead of being a silent, scheduled disappearance.
  #
  # OnUnitInactiveSec, not OnCalendar, on purpose: the interval is measured
  # from the END of the last run, so a slow or retrying run never stacks up
  # behind itself. It only works because the unit no longer sets
  # RemainAfterExit — a unit that never deactivates never gives this timer a
  # reference point.
  #
  # OnBootSec is the fallback anchor for a boot where the unit did not run at
  # all (the test profiles take it out of multi-user.target, so this is not
  # hypothetical). Six hours rather than minutes: the failure this exists for
  # is measured in months, so six hours of downtime against "never reconnects"
  # is the whole win, and a long first anchor keeps the timer out of the way of
  # the VM suites, which take the unit out of multi-user.target and then start
  # it by hand with a real preauth key.
  systemd.timers.tailscale-autoconnect = {
    description = "Re-register with Headscale before the node key expires";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "6h";
      OnUnitInactiveSec = "6h";
      # Nothing here is time-critical and every services-VM tick is a request
      # to the VPS; spread them.
      RandomizedDelaySec = "30min";
      # No Persistent: a missed tick means nothing, the next one re-checks.
      Unit = "tailscale-autoconnect.service";
    };
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

    # This is the deploy plane, and it had no failure path at all. Without it
    # Arcane is down: no stack can be deployed or updated, and no git sync
    # delivers anything — while every stack already running keeps running, so
    # nothing looks wrong until the next change silently does not land.
    onFailure = [ "notify-failure@%n.service" ];

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
      # The script fails the run when a stack is deployed but its database
      # container is not running — a stopped database used to be skipped
      # silently, which is a backup that is green and stores nothing. For a
      # stack that is deliberately stopped, name it (or its container) here
      # rather than letting it page nightly, e.g.
      #   Environment = "BACKUP_SKIP=docspace bookstack_db";
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
  #
  # TWO stamps with TWO windows, because backup-prepare does two unrelated
  # jobs. It used to write one stamp and skip it on any failure, so a VPS pull
  # that failed — a tailnet blip, a rebooting VPS — suppressed the stamp that
  # certifies every LOCAL database dump, and this canary then reported "backups
  # are stale" about backups that had all worked. That is alarm fatigue by
  # construction: the same notification for "no dumps at all" and "could not
  # reach the VPS tonight".
  #
  #   local  48h. The timer runs nightly, so this is two missed runs. This is
  #          the canary proper: if backup-prepare.timer stops firing, nothing
  #          else notices.
  #   VPS    7 days, deliberately looser. Each individual VPS-pull failure
  #          ALREADY pages the same night through backup-prepare's own
  #          OnFailure, so a 48h window here would only duplicate it. What this
  #          adds is the thing that notification cannot express: it has been
  #          broken for a week and nobody acted.
  #
  # Both legs report in one run, so a message never hides behind another.
  systemd.services.backup-staleness-check = {
    description = "Alert if backup preparation has not succeeded recently";
    onFailure = [ "notify-failure@%n.service" ];
    serviceConfig.Type = "oneshot";
    script = ''
      fail=0

      check() {
        stamp="$1"; limit="$2"; what="$3"
        if [ ! -f "$stamp" ]; then
          echo "$what: no success has ever been recorded ($stamp is missing)."
          fail=1
          return
        fi
        age=$(( $(date -u +%s) - $(cat "$stamp") ))
        if [ "$age" -gt "$limit" ]; then
          echo "$what: last success was $(( age / 3600 ))h ago (limit $(( limit / 3600 ))h)."
          fail=1
          return
        fi
        echo "$what: last succeeded $(( age / 3600 ))h ago."
      }

      check /mnt/fast/_dumps/.last-success-local 172800 \
            "local database dumps"
      check /mnt/fast/_dumps/.last-success-vps   604800 \
            "VPS state pull (authentik db + headscale keys)"

      exit "$fail"
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

  # ---------------------------------------------------------------------------
  # Unhealthy-container alerting
  # ---------------------------------------------------------------------------
  # NOTHING ELSE IN THIS FLEET REACTS TO A CONTAINER GOING `unhealthy`.
  # `restart: unless-stopped` only restarts containers that EXIT — a process
  # that is alive and failing its own healthcheck is restarted by nobody and
  # reported by nobody. Every stack here has carefully chosen healthchecks
  # (several of the ledger findings are about exactly that), and until this
  # unit they were consumed only by `depends_on` at start-up and by a human
  # running `docker ps`.
  #
  # Deliberately NOT a new container. The monitoring annex recommends this even
  # if Gatus and Beszel are eventually built, because it needs no service to be
  # up in order to work — which is the property you want from the thing that
  # tells you a service is down.
  #
  # Note what it does NOT do: it does not restart anything. Restarting a
  # container whose healthcheck is failing is as likely to hide a problem as
  # fix one (a database mid-migration, a service waiting on a dependency), and
  # the fleet has no evidence yet about which failures are transient here.
  # Alert first; automate a response once there is something to automate.
  systemd.services.unhealthy-containers = {
    description = "Alert on containers stuck in the unhealthy state";
    after = [ "docker.service" ];
    onFailure = [ "notify-failure@%n.service" ];
    path = [ config.virtualisation.docker.package ] ++ (with pkgs; [ coreutils ]);
    serviceConfig.Type = "oneshot";
    script = ''
      # `--filter health=unhealthy` excludes `starting`, so a container inside
      # its start_period never trips this — which matters, because several
      # stacks here have start periods of five minutes (firefly, wger) and a
      # naive check would page on every deploy.
      bad=$(docker ps --filter health=unhealthy --format '{{.Names}}' | sort)

      # Alert on state CHANGE, not on every tick — the same pattern
      # decrypt-sops-envs uses, and for the same reason: this runs on a timer
      # with OnFailure wired to ntfy, so exiting nonzero for as long as a
      # container is sick would be a phone push every 15 minutes forever. The
      # stamp lives in /run and is therefore cleared by a reboot.
      stamp=/run/unhealthy-containers.failed

      if [ -n "$bad" ]; then
        echo "Unhealthy containers:"
        echo "$bad"
        if [ -e "$stamp" ]; then
          echo "(already notified; see the journal above)"
          exit 0
        fi
        printf '%s\n' "$bad" > "$stamp"
        exit 1
      fi

      if [ -e "$stamp" ]; then
        echo "recovered: $(tr '\n' ' ' < "$stamp")"
        rm -f "$stamp"
      fi
      echo "no unhealthy containers"
    '';
  };

  systemd.timers.unhealthy-containers = {
    description = "Timer for the unhealthy-container check";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Every 15 minutes. Fast enough to matter, slow enough that a container
      # flapping through a restart does not page.
      OnCalendar = "*:0/15";
      # 3 minutes after boot, not immediately: docker and every stack need time
      # to get through their start periods first.
      OnBootSec = "3min";
      Persistent = false;
      Unit = "unhealthy-containers.service";
    };
  };

  # ---------------------------------------------------------------------------
  # Firefly III cron
  # ---------------------------------------------------------------------------
  # Firefly's recurring transactions, bill "paid" marks and auto-budget
  # rollovers only happen when something calls GET /api/v1/cron/<token>. Nothing
  # inside the container does it.
  #
  # Upstream's answer is a sidecar built on `alpine` that runs `apk add tzdata`
  # AT CONTAINER START and then loops on wget. That is finding #4 in
  # tests/README.md — a container that must fetch from the network to become
  # functional is a stack that breaks when the network does — so the sidecar is
  # deliberately absent from stacks/firefly/compose.yaml and this timer replaces
  # it. It also gets the failure path the sidecar never had: onFailure -> ntfy.
  #
  # Everything here is conditional on the stack actually being deployed, because
  # this unit ships with the host config while the stack is delivered by
  # Arcane's git sync — the two are not deployed together and this must be a
  # no-op in between.
  systemd.services.firefly-cron = {
    description = "Trigger Firefly III's scheduled tasks";
    after = [ "docker.service" ];
    onFailure = [ "notify-failure@%n.service" ];
    path = with pkgs; [ curl coreutils gnugrep ];
    serviceConfig.Type = "oneshot";
    script = ''
      env=/srv/stacks/firefly/.env

      # The stack is not deployed (or its .env has not been decrypted yet).
      # Silent success: this is the normal state on a host that does not run
      # Firefly, and alerting on it would train the alert to be ignored.
      if [ ! -r "$env" ]; then
        echo "$env not present - firefly stack not deployed, nothing to do."
        exit 0
      fi

      # Read verbatim, NOT sourced: the .env is a docker env_file, where a
      # value is everything after the first '=' with no shell quoting applied.
      # `source`-ing it would both mangle values and run anything in there.
      token=$(grep -m1 '^STATIC_CRON_TOKEN=' "$env" | cut -d= -f2-)

      # Length is checked HERE rather than left to Firefly: Binder\CLIToken
      # requires exactly 32 characters, and at any other length the route falls
      # through to per-user token handling and answers 500 — which curl reports
      # as a generic HTTP error that says nothing about the real cause.
      if [ "''${#token}" -ne 32 ]; then
        echo "STATIC_CRON_TOKEN in $env is ''${#token} chars, must be exactly 32."
        echo "Recurring transactions and bills are NOT being processed."
        exit 1
      fi

      # The loopback publish, not the Caddy vhost: this route takes no
      # authentication (the token is the credential), so going through Caddy
      # would only add the forward-auth outpost as a dependency of a cron job.
      curl -fsS --max-time 120 "http://127.0.0.1:10303/api/v1/cron/$token"
    '';
  };

  systemd.timers.firefly-cron = {
    description = "Timer for Firefly III scheduled tasks";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # 01:00, well clear of backup-prepare (02:45) and the Backrest window.
      OnCalendar = "*-*-* 01:00:00";
      Persistent = true;
      Unit = "firefly-cron.service";
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

    # Its failure is the quietest one on the box: the network simply does not
    # exist, every stack that declares `networks: [homelab]` fails to start
    # with a compose error nobody is watching, and Backrest's notifications —
    # which reach Ntfy at http://ntfy/ over exactly this network — are the
    # first casualty. Alert on it directly rather than waiting to notice the
    # silence.
    onFailure = [ "notify-failure@%n.service" ];

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
