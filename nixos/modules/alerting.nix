{ config, pkgs, ... }:

{
  # Failure notification
  # OnFailure= template -> ntfy on loopback :10001. Never fails itself: a
  # notifier that can fail just produces more failed units and no notification.
  #
  # Before adding OnFailure= to a unit, check its Restart=: OnFailure fires on
  # `failed`, which Restart=on-failure reaches only through the start limiter
  # (5 starts / 10s by default), so any RestartSec above ~3s leaves it as dead
  # code. tailscale-autoconnect carries explicit StartLimit* for that reason.
  systemd.services."notify-failure@" = {
    description = "Notify Ntfy that %i failed";
    serviceConfig.Type = "oneshot";
    scriptArgs = "%i";
    script = ''
      unit="$1"
      # Body on stdin, not argv: /proc/<pid>/cmdline is world-readable and the
      # excerpt can carry anything the failed unit logged.
      ${pkgs.systemd}/bin/systemctl status --full --lines=30 "$unit" 2>&1 \
        | head -c 3000 \
        | ${pkgs.curl}/bin/curl -fsS --max-time 20 \
            -H "Title: services-vm: $unit failed" \
            -H "Priority: high" \
            -H "Tags: rotating_light" \
            --data-binary @- \
            http://127.0.0.1:10001/alerts || echo "ntfy notification failed"
      exit 0
    '';
  };

  # Unhealthy containers
  # Nothing else in the fleet reacts to `unhealthy` — restart: unless-stopped
  # only restarts containers that EXIT. Deliberately alerts rather than
  # restarts.
  systemd.services.unhealthy-containers = {
    description = "Alert on containers stuck in the unhealthy state";
    after = [ "docker.service" ];
    onFailure = [ "notify-failure@%n.service" ];
    path = [ config.virtualisation.docker.package ] ++ (with pkgs; [ coreutils ]);
    serviceConfig.Type = "oneshot";
    script = ''
      # health=unhealthy excludes `starting`, so long start_periods (firefly,
      # wger) never page on deploy.
      bad=$(docker ps --filter health=unhealthy --format '{{.Names}}' | sort)

      # Alert on state CHANGE: suppress only while the SET is unchanged, so a
      # second container going unhealthy mid-incident is still a page.
      stamp=/run/unhealthy-containers.failed

      if [ -n "$bad" ]; then
        echo "Unhealthy containers:"
        echo "$bad"
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
      # Slow enough that a container flapping through a restart does not page.
      OnCalendar = "*:0/15";
      # Stacks need their start periods first.
      OnBootSec = "3min";
      Persistent = false;
      Unit = "unhealthy-containers.service";
    };
  };

  # VictoriaLogs disk budget
  # A failsafe, not the enforcement: stacks/logging pins
  # -retention.maxDiskSpaceUsageBytes=100GiB, but upstream documents that cap
  # as soft and a typo'd flag is a silent keep-everything-forever. The
  # threshold sits ABOVE the budget so it only fires once the cap has failed.
  systemd.services.victorialogs-quota-check = {
    description = "Alert when VictoriaLogs' store exceeds its disk budget (native cap failsafe)";
    onFailure = [ "notify-failure@%n.service" ];
    path = with pkgs; [ coreutils ];
    serviceConfig.Type = "oneshot";
    script = ''
      store=/mnt/slow/victorialogs
      limit=118111600640 # 110 GiB

      if [ ! -d "$store" ]; then
        echo "skip: $store does not exist (logging stack not deployed here)"
        exit 0
      fi

      used=$(du -sb "$store" | cut -f1)
      echo "victorialogs store: $(( used / 1024 / 1024 / 1024 )) GiB used at $store"

      # Alert on state CHANGE: a daily timer with OnFailure->ntfy would
      # otherwise push to the phone every day the store is oversized.
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
      # 04:30 clears the backup window (02:45 prepare, 03:00 fast plan).
      OnCalendar = "*-*-* 04:30:00";
      Persistent = true;
      Unit = "victorialogs-quota-check.service";
    };
  };

  # Fast-tier headroom
  # Every database lives on /mnt/fast, and one tenant there grows without
  # bound: Bitmagnet's index (regenerable, ~8 KB per crawled torrent, at its
  # tuned crawl rate ~17 GB/day). At 90% the crawler is stopped, before it
  # can fill the tier under everything else. Start it again by hand
  # (`docker start bitmagnet`) once the fast disk has grown
  # (`qm resize` + `grow-disk fast`) or the index has moved.
  systemd.services.fast-tier-headroom = {
    description = "Stop Bitmagnet before its index fills /mnt/fast";
    onFailure = [ "notify-failure@%n.service" ];
    path = [ pkgs.coreutils config.virtualisation.docker.package ];
    serviceConfig.Type = "oneshot";
    script = ''
      pct=$(df --output=pcent /mnt/fast | tail -1 | tr -dc 0-9)
      echo "/mnt/fast: $pct% used"
      # Alert on state CHANGE, as victorialogs-quota-check does.
      stamp=/run/fast-tier-headroom.over

      if [ "$pct" -ge 90 ]; then
        if [ "$(docker inspect -f '{{.State.Running}}' bitmagnet 2>/dev/null)" = true ]; then
          docker stop bitmagnet >/dev/null
          echo "STOPPED bitmagnet: /mnt/fast is at $pct%."
        fi
        if [ -e "$stamp" ]; then
          echo "(already notified; see the journal above)"
          exit 0
        fi
        : > "$stamp"
        exit 1
      fi

      if [ -e "$stamp" ]; then
        echo "recovered: back under 90%"
        rm -f "$stamp"
      fi
    '';
  };

  systemd.timers.fast-tier-headroom = {
    description = "Timer for the fast-tier headroom guard";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/15";
      Persistent = true;
      Unit = "fast-tier-headroom.service";
    };
  };
}
