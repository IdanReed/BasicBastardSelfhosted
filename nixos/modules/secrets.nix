{ pkgs, ... }:

{
  # YAML, not dotenv: sops-install-secrets applies the per-secret key only for
  # yaml/json — with dotenv every /run/secrets/<name> gets the whole file.
  sops = {
    defaultSopsFile = ../secrets.sops.yaml;
    defaultSopsFormat = "yaml";

    age.keyFile = "/var/lib/sops-nix/sops_age_key.txt";

    secrets = {
      TAILSCALE_AUTH_KEY = { };

      BACKUP_VPS_SSH_KEY = {
        path = "/var/lib/backup/vps_ed25519";
        mode = "0600";
      };

      # No custom path on purpose: backrest bind-mounts /var/lib/backup, where
      # a /run/secrets.d symlink dangles in-container. The tmpfiles C+ rule in
      # backup.nix materialises a real file instead.
      BACKUP_STORAGEBOX_SSH_KEY = {
        mode = "0600";
      };

      # Read-only Forgejo deploy key for stack-git-sync; consumed via
      # GIT_SSH_COMMAND, never argv.
      STACK_GIT_SSH_KEY = {
        mode = "0400";
      };
    };
  };

  # Decrypt .sops.env -> .env for /srv/komodo and every stack. Boot and a
  # minutely timer, because stack-git-sync delivers new .sops.env files at
  # runtime.
  systemd.services.decrypt-sops-envs = {
    description = "Decrypt .sops.env files to .env";
    after = [ "srv.mount" ];
    requires = [ "srv.mount" ];
    wantedBy = [ "multi-user.target" ];

    path = [ pkgs.sops ];

    serviceConfig = {
      Type = "oneshot";
      # NOT RemainAfterExit: an active oneshot absorbs every timer tick.
      # bootstrap-komodo's Requires= is satisfied by the start, not by
      # lingering.
    };

    script = ''
      # /srv/stacks is world-traversable; without this "$out.tmp" is briefly
      # born 0644.
      umask 077

      export SOPS_AGE_KEY_FILE=/var/lib/sops-nix/sops_age_key.txt

      # Failures accumulate: one bad .sops.env must not stop healthy stacks
      # decrypting, nor leave bootstrap-komodo's Requires= unsatisfied.
      fail=0
      failing=""

      decrypt() {
        src="$1"
        out="$(dirname "$src")/.env"
        # Inequality in either direction: a clock step can leave a "future"
        # .env that a strictly-newer check treats as fresh forever.
        if [ ! -e "$out" ] || [ "$src" -nt "$out" ] || [ "$src" -ot "$out" ]; then
          if sops -d "$src" > "$out.tmp"; then
            mv "$out.tmp" "$out"
            touch -r "$src" "$out"
          else
            # Keep the previous .env; journal + ntfy carry the failure.
            rm -f "$out.tmp"
            echo "FAILED to decrypt $src" >&2
            fail=1
            failing="$failing $src"
          fi
        fi
        # Outside the freshness guard so pre-existing root-owned .env files get
        # fixed without waiting for a change: the deploy plane reads these as
        # uid 1000 (finding #10).
        if [ -e "$out" ]; then
          chmod 600 "$out"
          chown 1000:1000 "$out"
        fi
      }

      [ -f /srv/komodo/.sops.env ] && decrypt /srv/komodo/.sops.env

      for f in /srv/stacks/*/.sops.env; do
        [ -f "$f" ] && decrypt "$f"
      done

      # Alert on state CHANGE: minutely + OnFailure->ntfy would otherwise page
      # every 60s. The stamp holds the failing SET, so a second stack breaking
      # mid-incident still pages.
      stamp=/run/decrypt-sops-envs.failed
      if [ "$fail" -ne 0 ]; then
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
      # The suites' 150s delivery waits assume prompt ticks; the 1min default
      # accuracy lets one slip ~120s.
      AccuracySec = "1s";
      Unit = "decrypt-sops-envs.service";
    };
  };
}
