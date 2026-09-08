{ config, pkgs, ... }:

{
  # Dumps + VPS state pull before Backrest's window. See ../backup-prepare.sh
  # for why this is not a Backrest command hook.
  systemd.services.backup-prepare = {
    description = "Pre-backup database dumps and VPS state pull";
    after = [ "docker.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    onFailure = [ "notify-failure@%n.service" ];

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
      ExecStart = "${pkgs.bash}/bin/bash ${../backup-prepare.sh}";
      # A deployed stack with a stopped DB container fails the run. For
      # deliberately stopped stacks:
      #   Environment = "BACKUP_SKIP=docspace bookstack_db";
    };
  };

  systemd.timers.backup-prepare = {
    description = "Timer for pre-backup preparation";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Ahead of the 03:00 fast-volume plan in stacks/backrest.
      OnCalendar = "*-*-* 02:45:00";
      Persistent = true;
      Unit = "backup-prepare.service";
    };
  };

  # Canary: a timer that stops firing produces no failure notification, so
  # something has to check for absence. Two stamps and two windows, because one
  # shared stamp let a failed VPS pull suppress the local-dump certificate.
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

      # 48h = two missed nightly runs. The VPS leg gets 7 days: each pull
      # failure already pages same-night via OnFailure.
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

  # storagebox_ed25519 must be a REAL file, not the sops-nix symlink: backrest
  # bind-mounts this directory and a /run/secrets.d symlink dangles
  # in-container. C+ re-copies on every switch, so never ssh-keygen here.
  systemd.tmpfiles.rules = [
    "d /var/lib/backup 0700 root root -"
    "C+ /var/lib/backup/storagebox_ed25519 0600 root root - ${config.sops.secrets.BACKUP_STORAGEBOX_SSH_KEY.path}"
  ];
}
