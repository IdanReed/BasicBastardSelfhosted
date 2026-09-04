{ config, pkgs, lib, ... }:

let
  # Copy of nixos-de/ssh-pubkeys.nix (flakes can't reference outside their
  # root); ssh-pubkey-parity lint guards drift.
  sshPubkeys = import ./ssh-pubkeys.nix;
in
{
  # Imports live HERE, not in flake.nix: tests/default.nix evaluates this file
  # directly, so a module listed only in the flake would deploy while staying
  # invisible to every lint (the drift module-list-parity catches on the VPS).
  imports = [
    ./modules/ci-secrets.nix
    ./modules/renovate.nix
    ./modules/forgejo-runner.nix
  ];

  # System identity
  networking.hostName = "services-vm";
  system.stateVersion = "25.11";

  # Static LAN IP — REQUIRED declaratively. 🚨 The image sets 10.0.0.3 via
  # cloud-init, but cloud-init lives only in the image build (flake.nix), so
  # every `nixos-rebuild switch` strips it from the running system. The IP
  # survived in RAM until the first real reboot (hit live 2026-09-04), then
  # NixOS's default DHCP grabbed a different address and everything expecting
  # 10.0.0.3 broke. Pin it here so it persists across reboots, independent of
  # cloud-init/DHCP. (iface ens18 = the virtio net0 predictable name.)
  networking.useDHCP = false;
  networking.interfaces.ens18.ipv4.addresses = [
    { address = "10.0.0.3"; prefixLength = 24; }
  ];
  networking.defaultGateway = "10.0.0.1";
  networking.nameservers = [ "10.0.0.1" ];

  # Timezone
  time.timeZone = "America/Chicago";

  # Silence kernel console messages
  boot.kernel.sysctl."kernel.printk" = "1 1 1 1";

  # User configuration
  users.users.idan = {
    isNormalUser = true;
    extraGroups = [ "wheel" "docker" ];
    shell = pkgs.bash;
    # null = key not yet generated = no access (not an eval failure); suites
    # merge their own key via profiles.testSshAccess.
    openssh.authorizedKeys.keys = lib.filter (k: k != null) [
      sshPubkeys.arcane-vm
    ];
  };

  # Deliberate trade (security review 2026-08-30): passwordless wheel is what
  # lets --use-remote-sudo and the backup pull run non-interactively; a
  # compromised authorized key IS instant root here. Mitigations sit upstream
  # of sudo (key-only auth, KbdInteractive off, sops-encrypted keys).
  security.sudo.wheelNeedsPassword = false;

  # Finding #4 (infra-review): caddy binds {$TAILNET_IP} (network_mode: host)
  # and crash-loops with EADDRNOTAVAIL at boot until tailscale0 has its
  # address. nonlocal_bind lets the bind succeed immediately; traffic flows
  # once the interface is up.
  boot.kernel.sysctl."net.ipv4.ip_nonlocal_bind" = 1;

  # nixos-rebuild --target-host pushes locally-built (unsigned) store paths;
  # the daemon accepts those only from a trusted user (hit live 2026-09-03:
  # "lacks a signature by a trusted key"). Wheel is already root-equivalent
  # here (passwordless sudo above), so this widens nothing.
  nix.settings.trusted-users = [ "root" "@wheel" ];

  # SSH server
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
      # Explicit (security review 2026-08-30 item 4): with UsePAM the default
      # `yes` opens a PAM password path PasswordAuthentication=false doesn't
      # close. Asserted by the vps suite.
      KbdInteractiveAuthentication = false;
    };
  };

  # Docker
  virtualisation.docker = {
    enable = true;
    # pkgs.docker is 28.x, marked insecure by nixpkgs — refuses to EVALUATE.
    # Matches headscale-vps.
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
    # 🚨 `docker logs` KEEPS WORKING — a contract (131 call sites in tests/).
    # Measured on docker 29.4.3: 202/202 lines readable, streams stay separate,
    # --tail/--timestamps identical, 2>&1 ordering byte-identical to json-file.
    # The one real behaviour change is journald rate limiting — see
    # services.journald below before touching either block.
    #
    # ⚠ Do NOT copy to headscale-vps: its authentik compose pins a PER-SERVICE
    # journald tag that fail2ban matches (fail2ban-journal-contract lint reads
    # the YAML; a daemon default is invisible to it). No fail2ban here.
    #
    # tag={{.Name}} is what makes the journal legible. With no tag, docker sets
    # CONTAINER_TAG (and SYSLOG_IDENTIFIER) to the TRUNCATED CONTAINER ID —
    # verified: a container run without the option logged CONTAINER_TAG
    # "931e9b6a5ce8". Every log stream label and every future journalmatch
    # would then be a value that changes on each `docker compose up`.
    # Per-service `logging:` blocks in a compose file override this default,
    # which is exactly how the VPS keeps its own pinned tag.
    #
    # Bonus: json-file had no max-size anywhere; journald is bounded by
    # SystemMaxUse below.
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
  # 🚨 rateLimitBurst = 0 MUST STAY IN LOCKSTEP WITH THE LOG DRIVER ABOVE.
  # journald rate-limits per sending unit and docker submits everything as
  # docker.service (verified via _SYSTEMD_UNIT), so the whole fleet shares ONE
  # bucket. A limited line never reaches the journal — `docker logs` loses it
  # too (measured at the default burst: 30000 emitted, 9994 readable, no
  # "Suppressed" note). 0 disables limiting (journald.conf(5)); the bound
  # moves to the byte cap below.
  services.journald = {
    rateLimitBurst = 0;

    # NixOS default, but explicit: the logging stack's premise is that a
    # reboot doesn't erase what Alloy hasn't shipped yet.
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

      # Incremental vacuuming, not one large delete.
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

  # 🚨 YAML, not dotenv: sops-install-secrets applies the per-secret key only
  # for yaml/json — with dotenv every /run/secrets/<name> receives the WHOLE
  # decrypted file (shipped once). Stack .sops.env files are unaffected: the
  # sops CLI consumes them whole in decrypt-sops-envs below.
  sops = {
    defaultSopsFile = ./secrets.sops.yaml;
    defaultSopsFormat = "yaml";

    age.keyFile = "/var/lib/sops-nix/sops_age_key.txt";

    secrets = {
      TAILSCALE_AUTH_KEY = { };

      # Host SSH identities (public halves in ssh-pubkeys.nix). Custom `path`
      # installs a sops-nix SYMLINK — fine here, backup-prepare.sh reads it
      # host-side.
      BACKUP_VPS_SSH_KEY = {
        path = "/var/lib/backup/vps_ed25519";
        mode = "0600";
      };

      # NO custom path, on purpose: backrest bind-mounts /var/lib/backup into
      # config-init, where a /run/secrets.d symlink dangles and the key gate
      # would refuse forever. The tmpfiles C+ rule below materialises a real
      # file instead.
      BACKUP_STORAGEBOX_SSH_KEY = {
        mode = "0600";
      };

      # Read-only Forgejo deploy key for stack-git-sync (SSH since 2026-09,
      # replaces the v1 read:repository token; an SSH key exists before
      # Forgejo does, killing the placeholder+rebuild dance at bring-up).
      # Root-only; consumed via GIT_SSH_COMMAND, never argv.
      STACK_GIT_SSH_KEY = {
        mode = "0400";
      };
    };
  };

  # Tailscale auto-login.
  #
  # --login-server is REQUIRED: without it the authkey goes to Tailscale's
  # SaaS control plane, where a Headscale preauth key silently fails.
  #
  # 🚨 NOT RemainAfterExit: `systemctl start` on an active oneshot is a no-op
  # and OnUnitInactiveSec= never sees a deactivation — the timer below would
  # never re-run it, and Headscale's 180-day node-key expiry would drop the
  # node with nothing ever re-running `tailscale up`. Nothing orders After=
  # this unit, so dropping it costs nothing.
  systemd.services.tailscale-autoconnect = {
    description = "Automatic connection to Headscale";
    # tailscaled.service, NOT tailscale.service — the latter has never existed
    # here and systemd silently ignores ordering on nonexistent units
    # (verified via config.systemd.units).
    after = [ "network-online.target" "tailscaled.service" ];
    wants = [ "network-online.target" "tailscaled.service" ];
    wantedBy = [ "multi-user.target" ];

    # Ntfy is loopback-local, so this notification still leaves the box even
    # when the thing that failed IS the tailnet.
    onFailure = [ "notify-failure@%n.service" ];

    # Sized so a TIMED-OUT cycle really reaches `failed` (OnFailure keys on
    # it): `tailscale up` blocks forever against an unreachable control plane
    # and oneshot TimeoutStartSec defaults to infinity, while the default
    # start limiter (5/10s) resets before RestartSec=30s ever trips it — both
    # paths retry silently forever without these caps. A timed-out cycle is
    # 8min + 30s; 3 starts land inside the 30min window, and 30min is well
    # under the 6h timer, so giving up is never permanent. Same trio as the
    # VPS twin.
    unitConfig = {
      StartLimitIntervalSec = "30min";
      StartLimitBurst = 3;
    };

    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = "8min";
      # The VPS may still be booting or reissuing certs; retry.
      Restart = "on-failure";
      RestartSec = "30s";
    };

    script = ''
      set -euo pipefail

      # Wait for a TERMINAL BackendState (up to 60s) — a single early sample
      # reads a healthy node mid-Starting as "not connected" and re-registers,
      # spending a SINGLE-USE preauth key for nothing.
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

      # Early exit makes the periodic re-run safe (while up, do NOTHING) and
      # repairs day-180: an expired node key reads NeedsLogin, falling through
      # to `tailscale up`. A spent preauth key then fails loudly via OnFailure
      # — correct, a human must mint a new one on the VPS.
      if [ "$state" = "Running" ]; then
        # Log key expiry each tick ("none" = no expiry set). Never allowed to
        # fail the unit — it's a log line.
        expiry="$(${pkgs.tailscale}/bin/tailscale status -json \
          | ${pkgs.jq}/bin/jq -r '.Self.KeyExpiry // "none"' 2>/dev/null || echo unknown)"
        echo "Already connected to Headscale (node key expiry: $expiry)"
        exit 0
      fi

      # `tailscale up` cannot fix this and would spend a preauth key trying.
      if [ "$state" = "NeedsMachineAuth" ]; then
        echo "Node is registered but awaiting authorisation on Headscale." >&2
        echo "Approve it on the VPS (headscale nodes list / register); NOT re-running tailscale up." >&2
        exit 1
      fi

      echo "Not connected (BackendState=$state) - registering against Headscale"

      # A changeme_* template value would register garbage against Headscale —
      # fail loudly instead. Only changeme_* is guarded: the suites overwrite
      # the fixtures' sentinel before starting this unit.
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

  # The self-heal half of the day-180 case (see the 🚨 block on the unit).
  # OnUnitInactiveSec, not OnCalendar: measured from the END of the last run,
  # so retries never stack — and only works without RemainAfterExit.
  # OnBootSec anchors boots where the unit didn't run (test profiles take it
  # out of multi-user.target); 6h because the failure mode is measured in
  # months and it keeps the timer out of the VM suites' way.
  systemd.timers.tailscale-autoconnect = {
    description = "Re-register with Headscale before the node key expires";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "6h";
      OnUnitInactiveSec = "6h";
      RandomizedDelaySec = "30min";
      # No Persistent: a missed tick means nothing, the next one re-checks.
      Unit = "tailscale-autoconnect.service";
    };
  };

  # Decrypt .sops.env -> .env for /srv/komodo and every stack, with the same
  # age key sops-nix uses. Boot AND a minutely timer: stack-git-sync delivers
  # new .sops.env files at runtime, and a boot-only oneshot would leave them
  # undecrypted until the next reboot. Make-style via tmpfile+rename, so
  # consumers never see a half-written .env and unchanged stacks see no
  # mtime churn.
  systemd.services.decrypt-sops-envs = {
    description = "Decrypt .sops.env files to .env";
    after = [ "srv.mount" ];
    requires = [ "srv.mount" ];
    wantedBy = [ "multi-user.target" ];

    path = [ pkgs.sops ];

    serviceConfig = {
      Type = "oneshot";
      # NOT RemainAfterExit: an active oneshot absorbs every timer tick and
      # the runtime-sync gap is back. bootstrap-komodo's Requires= is
      # satisfied by the start, not by lingering.
    };

    script = ''
      # /srv/stacks is world-traversable; without this "$out.tmp" is born 0644
      # for the moment before its chmod.
      umask 077

      export SOPS_AGE_KEY_FILE=/var/lib/sops-nix/sops_age_key.txt

      # Per-file failures accumulate: one bad .sops.env must not stop healthy
      # stacks from decrypting, nor leave bootstrap-komodo's Requires=
      # unsatisfied at boot. $failing (glob order, deterministic) feeds the
      # change-detection stamp below.
      fail=0
      failing=""

      decrypt() {
        src="$1"
        out="$(dirname "$src")/.env"
        # Inequality in EITHER direction, not just -nt: VM restores/NTP steps
        # can leave a "future" .env that a strictly-newer check treats as
        # fresh forever. touch -r pins out's mtime to src's, so "mtimes
        # differ" means exactly "src changed since the last good decrypt".
        if [ ! -e "$out" ] || [ "$src" -nt "$out" ] || [ "$src" -ot "$out" ]; then
          if sops -d "$src" > "$out.tmp"; then
            mv "$out.tmp" "$out"
            touch -r "$src" "$out"
          else
            # Keep the previous .env — a bad new file must not take down a
            # working stack. Journal + ntfy carry the failure.
            rm -f "$out.tmp"
            echo "FAILED to decrypt $src" >&2
            fail=1
            failing="$failing $src"
          fi
        fi
        # OUTSIDE the freshness guard: enforced every tick so pre-existing
        # root-owned .env files get fixed without waiting for a change. The
        # deploy plane reads these as uid 1000 (finding #10); root-owned 0600
        # is unreadable to it.
        if [ -e "$out" ]; then
          chmod 600 "$out"
          chown 1000:1000 "$out"
        fi
      }

      [ -f /srv/komodo/.sops.env ] && decrypt /srv/komodo/.sops.env

      for f in /srv/stacks/*/.sops.env; do
        [ -f "$f" ] && decrypt "$f"
      done

      # Alert on state CHANGE, not every tick — minutely + OnFailure->ntfy
      # would otherwise page every 60s for the duration. Stamp holds the
      # failing SET (a different stack breaking mid-incident must page again;
      # a bare existence check would swallow it). /run, so reboot clears it.
      stamp=/run/decrypt-sops-envs.failed
      if [ "$fail" -ne 0 ]; then
        # $(cat) strips the trailing newline, matching $failing.
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
      # Default AccuracySec is 1min — a "minutely" tick can slip ~120s, and
      # the suites' 150s delivery waits assume prompt ticks.
      AccuracySec = "1s";
      # No Persistent: a missed tick means nothing, the next one re-scans.
      Unit = "decrypt-sops-envs.service";
    };
  };

  # Komodo bootstrap — the deploy plane.
  systemd.services.bootstrap-komodo = {
    description = "Bootstrap Komodo container management";
    # Core joins `homelab` to reach Forgejo for Resource-Sync polling, so the
    # network is a real start dependency, not just an ordering edge.
    after = [ "docker.service" "network-online.target" "srv.mount" "decrypt-sops-envs.service" "docker-network-homelab.service" ];
    wants = [ "network-online.target" ];
    requires = [ "docker.service" "srv.mount" "decrypt-sops-envs.service" "docker-network-homelab.service" ];
    wantedBy = [ "multi-user.target" ];

    # Deploy plane down = running stacks keep running, so nothing looks wrong
    # until the next change silently doesn't land. Alert directly.
    onFailure = [ "notify-failure@%n.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      WorkingDirectory = "/srv/komodo";
    };

    script = ''
      sleep 5
      ${config.virtualisation.docker.package}/bin/docker compose up -d
    '';
  };

  # ---------------------------------------------------------------------------
  # Stack file delivery — the host-side clone Komodo's files_on_host needs
  # ---------------------------------------------------------------------------
  # The clone lives on the HOST (invariant #1: git credentials and file writes
  # stay out of the socket-mounting Periphery). Materialises
  # /srv/stacks/<name>/{compose.yaml,.sops.env} owned 1000:1000;
  # decrypt-sops-envs writes each .env; Core registers Stacks from the TOML
  # syncs.
  #
  # Timer-driven, NOT wantedBy multi-user.target: Forgejo — the remote — is
  # itself a managed stack, so a boot-time pull would race it and page. The
  # minutely timer converges once Forgejo is up; /srv/stacks is pre-seeded at
  # provisioning.
  systemd.services.stack-git-sync = {
    description = "Sync compose stacks from Forgejo into /srv/stacks";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    # Its silent failure is a stack that never updates — alert directly.
    onFailure = [ "notify-failure@%n.service" ];

    path = with pkgs; [
      git
      # git shells out to `ssh` for the ssh:// remote (GIT_SSH_COMMAND).
      openssh
      rsync
      coreutils
    ];

    serviceConfig = {
      Type = "oneshot";
      # Private root-owned checkout.
      StateDirectory = "stack-git-sync";
      StateDirectoryMode = "0700";
    };

    script = ''
      # NOT set -e: each step is `|| fail` so errors alert with a useful
      # message.
      set -uo pipefail
      umask 077

      # Loopback SSH, NOT the tailnet vhost: keeps tailscaled + Caddy + the
      # wildcard cert out of the dependency set (Caddy could not proxy SSH
      # anyway). 10551 is the forgejo stack's loopback sshd publish.
      host="127.0.0.1"
      port="10551"
      repo="idan/BasicBastardSelfhosted"
      branch="main"
      work="$STATE_DIRECTORY/checkout"
      url="ssh://git@$host:$port/$repo.git"

      # Deploy key via GIT_SSH_COMMAND — never argv. Host-key pinning model:
      # accept-new pins Forgejo's host key on FIRST loopback contact into the
      # root-only StateDirectory (Forgejo generates its host keys into
      # /data/ssh on first start, so there is no pre-boot artifact to pin
      # against); any later mismatch fails the unit loudly -> ntfy, which is
      # exactly the desired signal on /data loss. Fail fast rather than block
      # on a TTY prompt the oneshot cannot answer.
      export GIT_SSH_COMMAND="ssh -i ${config.sops.secrets.STACK_GIT_SSH_KEY.path} -o IdentitiesOnly=yes -o UserKnownHostsFile=$STATE_DIRECTORY/known_hosts -o StrictHostKeyChecking=accept-new"
      export GIT_TERMINAL_PROMPT=0

      # Alert on state CHANGE (the decrypt-sops-envs pattern): a persistent
      # failure must not ntfy every 60s. /run, so reboot clears it.
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

      # Clone once, fetch+reset thereafter: a force-push or diverged checkout
      # heals rather than wedging.
      if [ ! -d "$work/.git" ]; then
        rm -rf "$work"
        git clone --quiet --branch "$branch" "$url" "$work" \
          || fail "clone failed (is Forgejo's sshd reachable at $host:$port, deploy key registered?)"
      else
        git -C "$work" fetch --quiet origin "$branch" \
          || fail "fetch failed (is Forgejo's sshd reachable at $host:$port, deploy key registered?)"
        git -C "$work" reset --quiet --hard "origin/$branch" \
          || fail "reset to origin/$branch failed"
      fi

      [ -d "$work/stacks" ] || fail "repo checkout has no stacks/ directory"

      # --checksum: unchanged .sops.env keeps its mtime, so no minutely
      # re-decrypt. 🚨 NO --delete: the decrypted .env is absent from the
      # checkout and would be nuked — and teardown is the deploy plane's job,
      # not delivery's. Excludes are belt-and-suspenders.
      rsync -rlptD --checksum \
        --exclude='.env' --exclude='komodo.env' \
        "$work/stacks/" /srv/stacks/ \
        || fail "rsync into /srv/stacks failed"

      # 1000:1000 on delivered stacks (finding #10): rsync copies them
      # root-owned. Only the dirs this sync manages, never /srv/stacks itself.
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
      # Match decrypt-sops-envs; see its AccuracySec note.
      AccuracySec = "1s";
      # No Persistent: a missed tick means nothing, the next one re-syncs.
      Unit = "stack-git-sync.service";
    };
  };

  # ---------------------------------------------------------------------------
  # Failure notification
  # ---------------------------------------------------------------------------
  # OnFailure= template -> ntfy (loopback :10001, forwards to phone + email).
  # Never fails itself: a notifier that can fail just produces more failed
  # units and no notification.
  #
  # 🚨 BEFORE ADDING OnFailure= TO A UNIT, CHECK ITS Restart=. OnFailure fires
  # on `failed`, which Restart=on-failure only reaches via the start limiter —
  # default 5 starts per 10 SECONDS, so any RestartSec above ~3s resets the
  # window and the unit retries forever in `activating` with OnFailure= as
  # dead code. tailscale-autoconnect carries explicit StartLimit* for exactly
  # this; everything else here is a plain oneshot needing no limiter.
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
  # Dumps + VPS state pull before Backrest's window. See ./backup-prepare.sh
  # for why this is not a Backrest command hook.
  systemd.services.backup-prepare = {
    description = "Pre-backup database dumps and VPS state pull";
    after = [ "docker.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    onFailure = [ "notify-failure@%n.service" ];

    # The configured package, not pkgs.docker (28.x, marked insecure).
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
      # A deployed stack with a stopped DB container FAILS the run (silently
      # skipping = a green backup storing nothing). For deliberately stopped
      # stacks: Environment = "BACKUP_SKIP=docspace bookstack_db";
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

  # Local canary: a timer that stops firing produces no failure notification,
  # so something must check for absence. (The external dead-man's switch in
  # stacks/backrest covers this whole host being down.)
  #
  # TWO stamps, TWO windows — one shared stamp let a failed VPS pull suppress
  # the stamp certifying the LOCAL dumps (alarm fatigue by construction):
  #   local 48h  — two missed nightly runs; the canary proper.
  #   VPS 7 days — each pull failure already pages same-night via OnFailure;
  #                this adds "broken for a week and nobody acted".
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
  # NOTHING ELSE IN THE FLEET REACTS TO `unhealthy`: restart: unless-stopped
  # only restarts containers that EXIT. Deliberately not a container itself
  # (monitoring annex) — needs no service up to work. Deliberately does NOT
  # restart anything: restarting on a failing healthcheck hides as many
  # problems as it fixes; alert first.
  systemd.services.unhealthy-containers = {
    description = "Alert on containers stuck in the unhealthy state";
    after = [ "docker.service" ];
    onFailure = [ "notify-failure@%n.service" ];
    path = [ config.virtualisation.docker.package ] ++ (with pkgs; [ coreutils ]);
    serviceConfig.Type = "oneshot";
    script = ''
      # health=unhealthy excludes `starting`, so five-minute start_periods
      # (firefly, wger) never page on deploy.
      bad=$(docker ps --filter health=unhealthy --format '{{.Names}}' | sort)

      # Alert on state CHANGE (the decrypt-sops-envs pattern): suppress only
      # while the SET is unchanged — a second container going unhealthy
      # mid-incident is a new page. /run, cleared by reboot.
      stamp=/run/unhealthy-containers.failed

      if [ -n "$bad" ]; then
        echo "Unhealthy containers:"
        echo "$bad"
        # $(cat) strips the trailing newline, matching $bad.
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
      # Slow enough that a container flapping through a restart doesn't page.
      OnCalendar = "*:0/15";
      # Not immediately: stacks need their start periods first.
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

      # Not deployed is not a failure (backup-prepare's require_running
      # distinction).
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
  # Recurring transactions/bills/rollovers only happen on GET
  # /api/v1/cron/<token>; nothing in the container calls it. Upstream's cron
  # sidecar `apk add`s at container start (finding #4: network-to-function),
  # so it is deliberately absent and this timer replaces it — with the
  # failure path the sidecar never had. Conditional on deployment: the unit
  # ships with the host config, the stack arrives by git sync, and this must
  # no-op in between.
  systemd.services.firefly-cron = {
    description = "Trigger Firefly III's scheduled tasks";
    after = [ "docker.service" ];
    onFailure = [ "notify-failure@%n.service" ];
    path = with pkgs; [ curl coreutils gnugrep ];
    serviceConfig.Type = "oneshot";
    script = ''
      env=/srv/stacks/firefly/.env

      # Not deployed (or not yet decrypted) = silent success — the normal
      # state on a host without Firefly.
      if [ ! -r "$env" ]; then
        echo "$env not present - firefly stack not deployed, nothing to do."
        exit 0
      fi

      # Read verbatim, NOT sourced — an env_file value is everything after the
      # first '='; sourcing would mangle values and execute content.
      token=$(grep -m1 '^STATIC_CRON_TOKEN=' "$env" | cut -d= -f2-)

      # Binder\CLIToken requires exactly 32 chars; any other length falls
      # through to per-user token handling and a generic 500.
      if [ "''${#token}" -ne 32 ]; then
        echo "STATIC_CRON_TOKEN in $env is ''${#token} chars, must be exactly 32."
        echo "Recurring transactions and bills are NOT being processed."
        exit 1
      fi

      # Loopback, not the Caddy vhost: the token is the only credential, and
      # Caddy would just add the forward-auth outpost as a cron dependency.
      # URL on stdin, NOT argv: /proc/<pid>/cmdline is world-readable (same
      # narrowing as backup-prepare's MYSQL_PWD). Accepted, not fixed:
      # upstream puts the token in the URL PATH, so Firefly's own access log
      # line still reaches the journal and Loki.
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

  # Shared docker network: containers cannot reach a loopback-bound host port
  # and all published ports bind 127.0.0.1, so cross-stack traffic rides
  # service names on `homelab` (host.docker.internal does not resolve on
  # Linux — it silently ate every backup notification).
  systemd.services.docker-network-homelab = {
    description = "Create the shared 'homelab' docker network";
    after = [ "docker.service" ];
    requires = [ "docker.service" ];
    wantedBy = [ "multi-user.target" ];
    before = [ "bootstrap-komodo.service" ];

    # The quietest failure on the box: every `networks: [homelab]` stack fails
    # to start with a compose error nobody watches. Alert directly.
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

  # vps_ed25519 arrives as a sops-nix symlink; storagebox_ed25519 must be a
  # REAL file (backrest bind-mounts the directory; a /run/secrets.d symlink
  # dangles in-container). 🚨 C+ re-copies at boot and on every switch, so a
  # hand-made key here is silently overwritten — never ssh-keygen into
  # /var/lib/backup.
  systemd.tmpfiles.rules = [
    "d /var/lib/backup 0700 root root -"
    "C+ /var/lib/backup/storagebox_ed25519 0600 root root - ${config.sops.secrets.BACKUP_STORAGEBOX_SSH_KEY.path}"
  ];

  # 🚨 trustedInterfaces bypasses this list for tailnet traffic: anything a
  # container publishes on 0.0.0.0 is tailnet-reachable regardless of what is
  # listed here — which is why stacks bind published ports to 127.0.0.1 and
  # Caddy is the only path in. The deploy plane (loopback :10000, docker
  # socket behind it) is reachable via Caddy only.
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
