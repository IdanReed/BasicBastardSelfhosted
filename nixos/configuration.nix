{ config, pkgs, lib, ... }:

let
  # Byte-identical copy of nixos-de/ssh-pubkeys.nix (the canonical one) — a
  # flake cannot reference paths outside its own root, so each flake carries
  # its own copy and the ssh-pubkey-parity lint fails the harness on drift.
  sshPubkeys = import ./ssh-pubkeys.nix;

  # Feeds stack-git-sync's Forgejo token to git WITHOUT putting it in argv:
  # git calls GIT_ASKPASS for the basic-auth password and this prints the
  # sops-decrypted value. /proc/<pid>/cmdline is world-readable on this host
  # (firefly-cron makes the same narrowing), so the token never rides argv.
  stackGitAskpass = pkgs.writeShellScript "stack-git-askpass" ''
    exec cat ${config.sops.secrets.STACK_GIT_TOKEN.path}
  '';
in
{
  # Modules are imported HERE, not from nixos/flake.nix — deliberately, and
  # differently from headscale-vps.
  #
  # tests/default.nix builds this host's config as `evalHost [ sopsModule
  # ../nixos/configuration.nix ]`, i.e. it enters through this file and NOT
  # through the flake. A module listed in flake.nix instead would be deployed
  # to the real host while being invisible to every lint that reads
  # servicesConfig — which is precisely the drift the `module-list-parity`
  # lint exists to catch on the VPS, where the flake genuinely is the entry
  # point and tests/default.nix has to mirror its list by hand. Importing
  # from here means there is no second list to keep in sync, so this host
  # needs no such lint.
  imports = [
    ./modules/ci-secrets.nix
    ./modules/renovate.nix
    ./modules/forgejo-runner.nix
  ];

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

    # -------------------------------------------------------------------------
    # Log driver: journald, fleet-wide, SERVICES VM ONLY
    # -------------------------------------------------------------------------
    # stacks/logging (VictoriaLogs + Alloy + Grafana) reads the HOST JOURNAL. Alloy
    # gets two read-only bind mounts (/var/log/journal, /etc/machine-id) and NO
    # docker socket — that is the whole point of routing container stdout
    # through journald rather than running a log collector with root-equivalent
    # access to the daemon.
    #
    # 🚨 `docker logs` KEEPS WORKING, and that is a contract, not a hope: 131
    # call sites across tests/ read it, and every one uses the plain
    # `docker logs <name> 2>&1` form. Measured against docker 29.4.3 (the same
    # major as pkgs.docker_29) with the driver switched:
    #   - 202 emitted lines, 202 readable;
    #   - stdout and stderr stay on separate streams (`2>/dev/null` yields
    #     only stdout, `1>/dev/null` only stderr);
    #   - `--tail N` and `--timestamps` behave identically;
    #   - the merged ordering of `2>&1` is BYTE-IDENTICAL to json-file's —
    #     stdout groups ahead of stderr under both drivers, because that is
    #     the CLI's own pipe buffering, not a driver property.
    # The one behaviour that genuinely changes is covered by services.journald
    # below; read that comment before touching either of these.
    #
    # ⚠ SERVICES VM ONLY. Do NOT copy this to headscale-vps/configuration.nix.
    # The VPS's authentik container sets `logging: {driver: journald, options:
    # {tag: authentik-server}}` PER SERVICE in its compose file, and fail2ban's
    # jail and filter both pin `CONTAINER_TAG=authentik-server`. The
    # fail2ban-journal-contract lint reads that tag out of the compose YAML and
    # requires both consumers to match it — a daemon default is invisible to a
    # YAML parser, so it can neither satisfy nor break that lint. There is no
    # fail2ban on this host at all (`grep -rn fail2ban nixos/` is empty).
    #
    # tag={{.Name}} is what makes the journal legible. With no tag, docker sets
    # CONTAINER_TAG (and SYSLOG_IDENTIFIER) to the TRUNCATED CONTAINER ID —
    # verified: a container run without the option logged CONTAINER_TAG
    # "931e9b6a5ce8". Every log stream label and every future journalmatch
    # would then be a value that changes on each `docker compose up`.
    # Per-service `logging:` blocks in a compose file override this default,
    # which is exactly how the VPS keeps its own pinned tag.
    #
    # Bonus fix, not a side effect worth hiding: json-file had NO max-size or
    # max-file anywhere in this fleet, so container logs grew unbounded on
    # /mnt/fast/docker. journald is bounded by SystemMaxUse below.
    daemon.settings = {
      log-driver = "journald";
      log-opts = {
        tag = "{{.Name}}";
      };
    };
  };

  # ---------------------------------------------------------------------------
  # journald — the buffer every container now logs into
  # ---------------------------------------------------------------------------
  # 🚨 rateLimitBurst = 0 IS LOAD-BEARING AND MUST STAY IN LOCKSTEP WITH THE
  # LOG DRIVER ABOVE. journald rate-limits PER SENDING UNIT, and docker's
  # journald driver submits from dockerd itself — verified, every container
  # line lands with _SYSTEMD_UNIT=docker.service. So the entire fleet shares
  # ONE bucket, which at the systemd default (10000 messages / 30 s) is a few
  # chatty containers wide.
  #
  # And a rate-limited line is not merely missing from Loki; it never reaches
  # the journal, so `docker logs` cannot show it either. Measured on the same
  # 29.4.3 host at the default burst: a container emitting 30000 lines was
  # readable as 9994 — 20006 lines gone, and journald printed no "Suppressed N
  # messages" note about it. A suite that greps `docker logs` for a line
  # another container's chatter pushed out of the bucket fails intermittently
  # and blames the wrong stack. Setting either the burst or the interval to 0
  # disables rate limiting entirely (journald.conf(5)).
  #
  # The bound moves from a message rate to a byte cap, which is the honest
  # place for it — see SystemMaxUse.
  services.journald = {
    rateLimitBurst = 0;

    # Explicit, not defaulted (the house rule for anything load-bearing).
    # "persistent" is also NixOS's default, but the logging stack's whole
    # premise is that a reboot does not erase what Alloy has not shipped yet,
    # and a silent upstream default change would break that quietly.
    storage = "persistent";

    extraConfig = ''
      # SIZING. The journal is a BUFFER, not the archive — VictoriaLogs holds
      # up to 100 GiB (retention flags in stacks/logging/compose.yaml), Alloy
      # ships continuously, and the journal only has to cover the window in
      # which Alloy is down. 2 GB of it is days at this fleet's volume.
      #
      # It lives on `/` (the OS disk), NOT on /mnt/fast — the sized log tier
      # is VictoriaLogs' store on /mnt/slow, and this cap exists so
      # the log fleet can never fill the root filesystem and take the host
      # down with it. That is also why SystemKeepFree is set ABOVE systemd's
      # 15% default rather than left alone: the test VMs get an 8 GB disk
      # (tests/lib/mk-stack-suite.nix), where 15% is 1.2 GB and a 2 GB journal
      # would be a quarter of the disk. journald honours whichever of the two
      # binds first, so the pair is safe on both the 8 GB test VM and the real
      # host.
      SystemMaxUse=2G
      SystemKeepFree=2G

      # Bound one rotation step so vacuuming is incremental rather than a
      # single large delete that takes a chunk of history with it.
      SystemMaxFileSize=128M
    '';
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

      # Read-only Forgejo token for stack-git-sync's compose pull. Forgejo runs
      # with DISABLE_SSH=true (stacks/forgejo), so the design's "deploy key" is
      # necessarily a git-over-HTTP token, not an SSH key — read over loopback,
      # same path modules/renovate.nix takes to keep the tailnet out of the
      # dependency set. Root-only; the host unit consumes it via GIT_ASKPASS.
      STACK_GIT_TOKEN = {
        mode = "0400";
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
    # tailscaled.service, NOT tailscale.service. `services.tailscale.enable`
    # defines the daemon as `tailscaled`; there has never been a unit called
    # `tailscale.service` on this host. systemd silently ignores After=/Wants=
    # on a unit that does not exist, so this ordering has been a no-op — the
    # unit could start before the daemon and the only thing hiding it was the
    # `sleep`/poll below. (Verified: builtins.hasAttr "tailscale.service"
    # config.systemd.units is false, "tailscaled.service" is true.)
    after = [ "network-online.target" "tailscaled.service" ];
    wants = [ "network-online.target" "tailscaled.service" ];
    wantedBy = [ "multi-user.target" ];

    # The tailnet going away takes the SSH path to this host with it, so a
    # human finds out by trying to log in. Ntfy is loopback-local
    # (127.0.0.1:10001) and does not ride the tailnet, so this notification
    # still leaves the box even when the thing that failed is the tailnet.
    onFailure = [ "notify-failure@%n.service" ];

    # Bounds the retry loop below so it can actually reach the `failed` state.
    # OnFailure= keys on `failed`, and a unit with Restart=on-failure only gets
    # there by tripping the start limiter — whose DEFAULT is 5 starts per 10
    # SECONDS. With RestartSec=30s the window resets before the burst is ever
    # reached, so this unit retried silently forever, reported `activating`,
    # and any OnFailure= on it would have been dead code.
    #
    # Sized against a TIMED-OUT cycle, not a fast one. `tailscale up` blocks
    # indefinitely when the control plane is unreachable — the exact scenario
    # above — and Type=oneshot defaults TimeoutStartSec to infinity, so without
    # the cap below the unit sits in `activating` forever: the limiter never
    # trips, OnFailure never fires, and OnUnitInactiveSec=6h never gets the
    # deactivation it measures from. Same trio as the VPS twin
    # (headscale-vps/configuration.nix), for the same reason.
    #
    # The three numbers are sized against each other:
    #   - 8min bounds an attempt without cutting a legitimate one short (the
    #     script's own bounded wait is 60s, and a real `tailscale up` against a
    #     slow-booting VPS is well inside that);
    #   - a timed-out cycle is then 8min + RestartSec 30s = 8.5min, so 3 starts
    #     span ~17min and the 4th lands at ~25.5min — inside the 30min window,
    #     so the limit is genuinely reached and the unit really enters `failed`.
    #     The old 20/1h could not: 20 timed-out cycles need ~2.8h, so the unit
    #     would have retried forever without ever notifying.
    #   - 30min is well under the 6h timer below, which retries afterwards, so
    #     giving up is never permanent.
    unitConfig = {
      StartLimitIntervalSec = "30min";
      StartLimitBurst = 3;
    };

    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = "8min";
      # The VPS may still be booting or reissuing certificates. Retry rather
      # than sitting off the tailnet until someone reruns this by hand.
      Restart = "on-failure";
      RestartSec = "30s";
    };

    script = ''
      set -euo pipefail

      # WAIT FOR A TERMINAL BackendState — do not sample once after `sleep 2`.
      #
      # This decides whether to run `tailscale up --authkey`, and the state
      # machine passes through NoState and Starting on the way to Running. A
      # single early sample can therefore read a perfectly healthy node as
      # "not connected" and re-register it, which on a SINGLE-USE Headscale
      # preauth key spends the key for nothing and leaves the next real
      # reconnection with no way in. Poll for up to 60s instead; the states
      # below are the ones that actually mean something.
      state=""
      for _ in $(${pkgs.coreutils}/bin/seq 1 30); do
        state="$(${pkgs.tailscale}/bin/tailscale status -json 2>/dev/null \
                 | ${pkgs.jq}/bin/jq -r '.BackendState // empty' || true)"
        case "$state" in
          Running | NeedsLogin | NeedsMachineAuth | Stopped) break ;;
        esac
        sleep 2
      done
      [ -n "$state" ] || state=NoState

      # The early exit is what makes the periodic re-run safe: while the node
      # is up, the timer's job is to do NOTHING.
      #
      # It is also why the re-run can repair the day-180 case: an expired node
      # key leaves BackendState at NeedsLogin, not Running, so the next tick
      # falls through to `tailscale up` and re-registers. If the stored preauth
      # key is itself spent or expired, that fails — loudly, through OnFailure
      # above, which is the correct outcome: nothing automatic can fix it and a
      # human has to mint a new key on the VPS.
      if [ "$state" = "Running" ]; then
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

      # Registered, but Headscale has not authorised the node. `tailscale up`
      # cannot fix this and would spend a single-use preauth key trying, so
      # fail and say what the human has to do instead.
      if [ "$state" = "NeedsMachineAuth" ]; then
        echo "Node is registered but awaiting authorisation on Headscale." >&2
        echo "Approve it on the VPS (headscale nodes list / register); NOT re-running tailscale up." >&2
        exit 1
      fi

      echo "Not connected (BackendState=$state) - registering against Headscale"

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
      # the runtime-sync gap would be back. bootstrap-komodo's Requires= is
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
      # boot, cannot leave bootstrap-komodo's Requires= forever unsatisfied
      # over a single broken stack. $failing collects WHICH files failed
      # (glob order, so deterministic) for the change-detection stamp below.
      fail=0
      failing=""

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
            failing="$failing $src"
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

      [ -f /srv/komodo/.sops.env ] && decrypt /srv/komodo/.sops.env

      for f in /srv/stacks/*/.sops.env; do
        [ -f "$f" ] && decrypt "$f"
      done

      # Alert on state CHANGE, not on every tick. This unit runs minutely with
      # OnFailure wired to ntfy, so exiting nonzero for as long as a stack is
      # broken would be a phone push every 60s forever. The stamp holds the
      # failing SET and survives between ticks (cleared by reboot with the
      # rest of /run): a changed set exits 1 and notifies, an unchanged one
      # stays in the journal only, and recovery is logged when the stamp is
      # removed.
      stamp=/run/decrypt-sops-envs.failed
      if [ "$fail" -ne 0 ]; then
        # Suppress only while the SET of failing files is unchanged: a
        # different stack breaking during an open incident must page again,
        # which a bare existence check would swallow until the first one
        # recovered. $(cat) strips the trailing newline, matching $failing.
        if [ -e "$stamp" ] && [ "$failing" = "$(cat "$stamp")" ]; then
          echo "decryption still failing (already notified; see journal above)" >&2
          exit 0
        fi
        printf '%s\n' "$failing" > "$stamp"
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

  # Komodo bootstrap service — the deploy plane (replaces Arcane).
  systemd.services.bootstrap-komodo = {
    description = "Bootstrap Komodo container management";
    # docker-network-homelab.service added over the Arcane wiring: Komodo Core
    # joins `homelab` to reach Forgejo for Resource-Sync polling, so the shared
    # network is a real start dependency, not just an ordering edge.
    after = [ "docker.service" "network-online.target" "srv.mount" "decrypt-sops-envs.service" "docker-network-homelab.service" ];
    wants = [ "network-online.target" ];
    requires = [ "docker.service" "srv.mount" "decrypt-sops-envs.service" "docker-network-homelab.service" ];
    wantedBy = [ "multi-user.target" ];

    # This is the deploy plane, and it had no failure path at all. Without it
    # Komodo is down: no stack can be deployed or updated, and no Resource Sync
    # registers anything — while every stack already running keeps running, so
    # nothing looks wrong until the next change silently does not land.
    onFailure = [ "notify-failure@%n.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      WorkingDirectory = "/srv/komodo";
    };

    script = ''
      # Wait for docker to be fully ready
      sleep 5

      # Start Komodo Core + Periphery + FerretDB + Postgres
      ${config.virtualisation.docker.package}/bin/docker compose up -d
    '';
  };

  # ---------------------------------------------------------------------------
  # Stack file delivery — the host-side clone Komodo's files_on_host needs
  # ---------------------------------------------------------------------------
  # Arcane cloned the compose repo INSIDE the socket-mounting container; Komodo
  # Periphery reads pre-existing files (files_on_host), so the clone moves to
  # the host — git credentials and file writes now leave the socket-toucher.
  # This unit pulls the compose repo and materialises /srv/stacks/<name>/{
  # compose.yaml,.sops.env} owned 1000:1000; decrypt-sops-envs then writes each
  # .env, and Komodo Core registers the Stacks from the git TOML syncs.
  #
  # Timer-driven, NOT wantedBy multi-user.target: /srv/stacks is pre-seeded at
  # provisioning (as /srv/komodo was for Arcane) and Forgejo — the git remote —
  # is itself a managed stack, so a boot-time pull would race a not-yet-running
  # Forgejo and page. The minutely timer converges once Forgejo is up.
  systemd.services.stack-git-sync = {
    description = "Sync compose stacks from Forgejo into /srv/stacks";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    # Its silent failure is a stack that never updates — alert directly.
    onFailure = [ "notify-failure@%n.service" ];

    path = with pkgs; [ git rsync coreutils ];

    serviceConfig = {
      Type = "oneshot";
      # Private root-owned checkout; the age key never enters here and this is
      # not the socket-toucher, so no secret material lives in it.
      StateDirectory = "stack-git-sync";
      StateDirectoryMode = "0700";
    };

    script = ''
      # NOT set -e: each step is guarded by `|| fail` so one error alerts with a
      # useful message instead of a bare nonzero exit.
      set -uo pipefail
      umask 077

      # Loopback HTTP, NOT the tailnet vhost — same reasoning as
      # modules/renovate.nix: keep tailscaled + Caddy + the wildcard cert out of
      # the sync's dependency set. Forgejo has DISABLE_SSH=true, so the "deploy
      # key" is a read-only Forgejo token (basic-auth password), not an SSH key.
      host="127.0.0.1:10550"
      user="idan"
      repo="idan/BasicBastardSelfhosted"
      branch="main"
      work="$STATE_DIRECTORY/checkout"
      url="http://$user@$host/$repo.git"

      # Token via GIT_ASKPASS (see stackGitAskpass) — never in argv. Fail fast
      # instead of blocking on a TTY prompt the oneshot has no way to answer.
      export GIT_ASKPASS=${stackGitAskpass}
      export GIT_TERMINAL_PROMPT=0

      # Alert on state CHANGE, not every tick — the decrypt-sops-envs pattern:
      # a persistent failure (Forgejo briefly down) must not ntfy every 60s.
      # The stamp holds the last failure message and lives in /run (reboot
      # clears it). Recovery is logged when the stamp is removed below.
      stamp=/run/stack-git-sync.failed

      fail() {
        echo "$1" >&2
        if [ -e "$stamp" ] && [ "$1" = "$(cat "$stamp")" ]; then
          echo "(already notified; see the journal above)" >&2
          exit 0
        fi
        printf '%s\n' "$1" > "$stamp"
        exit 1
      }

      # Clone once, fetch+reset thereafter so a force-push or a diverged
      # checkout heals rather than wedging the sync.
      if [ ! -d "$work/.git" ]; then
        rm -rf "$work"
        git clone --quiet --branch "$branch" "$url" "$work" \
          || fail "clone failed (is Forgejo reachable at $host?)"
      else
        git -C "$work" fetch --quiet origin "$branch" \
          || fail "fetch failed (is Forgejo reachable at $host?)"
        git -C "$work" reset --quiet --hard "origin/$branch" \
          || fail "reset to origin/$branch failed"
      fi

      [ -d "$work/stacks" ] || fail "repo checkout has no stacks/ directory"

      # Make-style delivery: --checksum copies only content-changed files, so an
      # unchanged .sops.env keeps its mtime and decrypt-sops-envs does not
      # re-decrypt it every minute. NO --delete: the decrypted .env is
      # gitignored and absent from the checkout, so --delete would nuke it —
      # and tearing a stack down is the deploy plane's job, not delivery's. The
      # excludes are belt-and-suspenders in case a stray .env is ever committed.
      rsync -rlptD --checksum \
        --exclude='.env' --exclude='komodo.env' \
        "$work/stacks/" /srv/stacks/ \
        || fail "rsync into /srv/stacks failed"

      # 1000:1000 on the delivered stacks (finding #10 world): rsync copies them
      # root-owned from the checkout. Only the dirs this sync manages, never
      # /srv/stacks itself (root, owned by the hand-written tmpfiles rule).
      for d in "$work"/stacks/*/; do
        name="$(basename "$d")"
        [ -d "/srv/stacks/$name" ] && chown -R 1000:1000 "/srv/stacks/$name"
      done

      if [ -e "$stamp" ]; then
        rm -f "$stamp"
        echo "recovered: stack sync succeeded again"
      fi
      exit 0
    '';
  };

  systemd.timers.stack-git-sync = {
    description = "Poll Forgejo for compose stack changes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "minutely";
      # Match decrypt-sops-envs: the suites' delivery waits assume prompt ticks,
      # and systemd's 1min default accuracy would slip a minutely tick by ~120s.
      AccuracySec = "1s";
      # No Persistent: a missed tick means nothing, the next one re-syncs.
      Unit = "stack-git-sync.service";
    };
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
  #
  # 🚨 BEFORE ADDING OnFailure= TO A UNIT, CHECK ITS Restart=. OnFailure fires
  # on the `failed` state, and a unit with Restart=on-failure only reaches it
  # by tripping the start limiter — default 5 starts per 10 SECONDS. Any
  # RestartSec above about 3s makes that window reset before the burst is
  # reached, so the unit retries forever in `activating` and the OnFailure= is
  # dead code that looks like coverage. tailscale-autoconnect is the one unit
  # here with Restart=, and it carries an explicit StartLimitIntervalSec /
  # StartLimitBurst for exactly this reason. Everything else in this file is a
  # plain oneshot with no Restart=, which fails on the first bad exit and needs
  # no limiter.
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
        # Suppress only while the SET is unchanged. A second container going
        # unhealthy during an open incident is a new page, not a repeat of the
        # old one — a bare existence check would swallow it until the first
        # container recovered. $(cat) strips the trailing newline, matching
        # the command-substituted $bad.
        if [ -e "$stamp" ] && [ "$bad" = "$(cat "$stamp")" ]; then
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
  # Loki disk budget
  # ---------------------------------------------------------------------------
  # 🚨 THIS IS NOW A FAILSAFE, NOT THE ENFORCEMENT. VictoriaLogs — unlike the
  # Loki it replaced — HAS native size-based retention:
  # -retention.maxDiskSpaceUsageBytes=100GiB in stacks/logging/compose.yaml
  # drops the oldest per-day partitions at the cap. But upstream documents the
  # cap as soft (it always keeps the last two days, even over budget), and a
  # typo'd flag is a silent keep-everything-forever — so the du check stays,
  # remeaning as "the native cap is not holding", with the threshold ABOVE the
  # budget rather than below it: 110 GiB fires only when the cap has already
  # failed to do its job, not while it is routinely working near the line.
  #
  # Why not gatus: gatus probes HTTP endpoints and has no notion of a
  # filesystem. Why not beszel: its agent reports the whole /mnt/slow
  # filesystem via statfs on the fsprobe marker directory, which is genuinely
  # useful for the tier but says nothing about which directory grew — and
  # /mnt/slow is 80 TB, so the store could be 40x over budget without moving
  # that gauge perceptibly. A per-directory number needs a per-directory check.
  systemd.services.victorialogs-quota-check = {
    description = "Alert when VictoriaLogs' store exceeds its disk budget (native cap failsafe)";
    onFailure = [ "notify-failure@%n.service" ];
    path = with pkgs; [ coreutils ];
    serviceConfig.Type = "oneshot";
    script = ''
      store=/mnt/slow/victorialogs
      # 110 GiB, above the 100 GiB native cap on purpose (see header). In
      # bytes so there is no rounding argument about which "GB" is meant.
      limit=118111600640

      # Not deployed is not a failure — the same distinction backup-prepare's
      # require_running makes. A missing directory means the logging stack has
      # not been synced onto this host yet, which the dump list and this check
      # are both allowed to run ahead of.
      if [ ! -d "$store" ]; then
        echo "skip: $store does not exist (logging stack not deployed here)"
        exit 0
      fi

      used=$(du -sb "$store" | cut -f1)
      echo "victorialogs store: $(( used / 1024 / 1024 / 1024 )) GiB used at $store"

      # Alert on state CHANGE, not on every tick — the same pattern
      # unhealthy-containers and decrypt-sops-envs use, and for the same
      # reason: this runs on a timer with OnFailure wired to ntfy, so exiting
      # nonzero for as long as the store is oversized would be a daily phone
      # push forever. The stamp lives in /run and is cleared by a reboot.
      stamp=/run/victorialogs-quota.over

      if [ "$used" -gt "$limit" ]; then
        echo "OVER BUDGET: $(( used / 1024 / 1024 / 1024 )) GiB exceeds the 110 GiB failsafe (100 GiB native cap)."
        echo "The native cap is not holding: check -retention.maxDiskSpaceUsageBytes in"
        echo "stacks/logging/compose.yaml is present in the running container's argv."
        if [ -e "$stamp" ]; then
          echo "(already notified; see the journal above)"
          exit 0
        fi
        printf '%s\n' "$used" > "$stamp"
        exit 1
      fi

      if [ -e "$stamp" ]; then
        echo "recovered: back under the threshold"
        rm -f "$stamp"
      fi
    '';
  };

  systemd.timers.victorialogs-quota-check = {
    description = "Timer for the VictoriaLogs disk-budget failsafe";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Daily, and deliberately not more often: `du` over a 100 GiB tree is
      # cheap but not free, and the quantity it measures moves over days.
      # 04:30 is after the backup window (02:45 prepare, 03:00 fast plan) so
      # the two never contend for the disk.
      OnCalendar = "*-*-* 04:30:00";
      Persistent = true;
      Unit = "victorialogs-quota-check.service";
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
      #
      # URL on stdin (`--config -`), NOT in argv: the token IS the credential
      # and /proc/<pid>/cmdline is world-readable on this host, where the PID
      # namespace is a superset of every container's and CI workflows run as a
      # DynamicUser (modules/forgejo-runner.nix). Same narrowing backup-prepare.sh
      # makes with MYSQL_PWD.
      #
      # Accepted, not fixed: Firefly puts the token in the URL PATH, so its own
      # access log line (`GET /api/v1/cron/<token>`) still reaches the journal
      # and Loki's 30-day retention. That is inherent to upstream's design.
      printf 'url = "http://127.0.0.1:10303/api/v1/cron/%s"\n' "$token" \
        | curl -fsS --max-time 120 --config -
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
    before = [ "bootstrap-komodo.service" ];

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
