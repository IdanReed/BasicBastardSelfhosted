{ config, pkgs, ... }:

{
  # Firefly's recurring transactions and bills only run on GET
  # /api/v1/cron/<token> and nothing in the container calls it; upstream's cron
  # sidecar `apk add`s at start, so this replaces it. The token is the same
  # sops-nix secret the stack's rendered env carries.
  systemd.services.firefly-cron = {
    description = "Trigger Firefly III's scheduled tasks";
    after = [ "docker.service" ];
    onFailure = [ "notify-failure@%n.service" ];
    path = with pkgs; [ curl coreutils gnugrep ];
    serviceConfig.Type = "oneshot";
    script = ''
      # Nothing answering = the stack is not deployed (or is mid-redeploy):
      # nothing to trigger, not a failure.
      if ! curl -s -o /dev/null --max-time 10 http://127.0.0.1:10303/; then
        echo "firefly is not answering on 127.0.0.1:10303 - nothing to do."
        exit 0
      fi

      src=${config.sops.secrets."stacks/firefly/STATIC_CRON_TOKEN".path}
      token=$(cat "$src")

      # Binder\CLIToken requires exactly 32 chars; anything else falls through
      # to per-user token handling and a generic 500.
      if [ "''${#token}" -ne 32 ]; then
        echo "STATIC_CRON_TOKEN ($src) is ''${#token} chars, must be exactly 32."
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
