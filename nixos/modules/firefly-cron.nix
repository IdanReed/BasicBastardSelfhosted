{ pkgs, ... }:

{
  # Firefly's recurring transactions and bills only run on GET
  # /api/v1/cron/<token> and nothing in the container calls it; upstream's cron
  # sidecar `apk add`s at start, so this replaces it. No-ops until the stack
  # arrives by git sync.
  systemd.services.firefly-cron = {
    description = "Trigger Firefly III's scheduled tasks";
    after = [ "docker.service" ];
    onFailure = [ "notify-failure@%n.service" ];
    path = with pkgs; [ curl coreutils gnugrep ];
    serviceConfig.Type = "oneshot";
    script = ''
      env=/srv/stacks/firefly/.env

      if [ ! -r "$env" ]; then
        echo "$env not present - firefly stack not deployed, nothing to do."
        exit 0
      fi

      # Read verbatim, not sourced: an env_file value is everything after the
      # first '=', and sourcing would mangle it and execute content.
      token=$(grep -m1 '^STATIC_CRON_TOKEN=' "$env" | cut -d= -f2-)

      # Binder\CLIToken requires exactly 32 chars; anything else falls through
      # to per-user token handling and a generic 500.
      if [ "''${#token}" -ne 32 ]; then
        echo "STATIC_CRON_TOKEN in $env is ''${#token} chars, must be exactly 32."
        echo "Recurring transactions and bills are NOT being processed."
        exit 1
      fi

      # Loopback, not the Caddy vhost: the token is the only credential and
      # Caddy would add the forward-auth outpost as a cron dependency. URL on
      # stdin, not argv, because /proc/<pid>/cmdline is world-readable.
      printf 'url = "http://127.0.0.1:10303/api/v1/cron/%s"\n' "$token" \
        | curl -fsS --max-time 120 --config -
    '';
  };

  systemd.timers.firefly-cron = {
    description = "Timer for Firefly III scheduled tasks";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Clear of backup-prepare (02:45) and the Backrest window.
      OnCalendar = "*-*-* 01:00:00";
      Persistent = true;
      Unit = "firefly-cron.service";
    };
  };
}
