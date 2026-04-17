{ config, pkgs, lib, ... }:

# Stack Sync Service
# Polls git repo, syncs stacks, decrypts secrets, runs docker compose
# This replaces Arcane's git sync since Arcane only pulls compose files

let
  cfg = config.services.stack-sync;
in
{
  options.services.stack-sync = {
    repoUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://github.com/idanreed/BasicBastardSelfhosted.git";
      description = "Git repository URL for stack configurations";
    };
  };
  # Stack sync script
  environment.etc."stack-sync/sync.sh" = {
    mode = "0755";
    text = ''
      #!/bin/bash
      set -euo pipefail

      REPO_URL="${cfg.repoUrl}"
      REPO_DIR="/srv/repo/BasicBastardSelfhosted"
      STACKS_DIR="/srv/stacks"
      export SOPS_AGE_KEY_FILE="/var/lib/sops-nix/key.txt"

      # Clone repo if not exists
      if [ ! -d "$REPO_DIR/.git" ]; then
        echo "Cloning repository..."
        git clone "$REPO_URL" "$REPO_DIR"
      fi

      cd "$REPO_DIR"

      # Fetch and check for changes
      git fetch origin main
      LOCAL=$(git rev-parse HEAD)
      REMOTE=$(git rev-parse origin/main)

      if [ "$LOCAL" = "$REMOTE" ]; then
        echo "No changes detected"
        exit 0
      fi

      echo "Changes detected, pulling..."
      git reset --hard origin/main

      # Sync and deploy each VPS stack
      for stack in authentik headscale; do
        src="$REPO_DIR/stacks/$stack"
        dest="$STACKS_DIR/$stack"

        if [ ! -d "$src" ]; then
          echo "Stack $stack not found in repo, skipping"
          continue
        fi

        echo "Syncing stack: $stack"
        mkdir -p "$dest"

        # Sync all files except encrypted secrets
        ${pkgs.rsync}/bin/rsync -av --exclude='.sops.env' "$src/" "$dest/"

        # Decrypt secrets if they exist
        if [ -f "$src/.sops.env" ]; then
          echo "Decrypting secrets for $stack"
          ${pkgs.sops}/bin/sops --decrypt "$src/.sops.env" > "$dest/.env"
          chmod 600 "$dest/.env"
        fi

        # Deploy with docker compose
        echo "Deploying $stack"
        cd "$dest"
        ${pkgs.docker}/bin/docker compose pull --quiet
        ${pkgs.docker}/bin/docker compose up -d --remove-orphans
      done

      # Copy Headscale config if it exists
      if [ -f "$REPO_DIR/stacks/headscale/config.yaml" ]; then
        echo "Copying Headscale config"
        cp "$REPO_DIR/stacks/headscale/config.yaml" /srv/headscale/config/config.yaml
      fi

      echo "Stack sync complete"
    '';
  };

  # Systemd service for stack sync
  systemd.services.stack-sync = {
    description = "Sync and deploy Docker stacks from git";
    after = [ "network-online.target" "docker.service" ];
    wants = [ "network-online.target" ];
    requires = [ "docker.service" ];

    path = with pkgs; [ git docker sops rsync coreutils bash ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "/etc/stack-sync/sync.sh";
      # Don't fail the whole service if one stack fails
      SuccessExitStatus = "0 1";
    };
  };

  # Timer to run stack-sync every 2 minutes
  systemd.timers.stack-sync = {
    description = "Timer for stack sync";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "2min";
      Unit = "stack-sync.service";
    };
  };

  # Initial stack deployment on boot
  systemd.services.stack-sync-initial = {
    description = "Initial stack deployment on boot";
    after = [ "network-online.target" "docker.service" ];
    wants = [ "network-online.target" ];
    requires = [ "docker.service" ];
    wantedBy = [ "multi-user.target" ];

    path = with pkgs; [ git docker sops rsync coreutils bash ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "/etc/stack-sync/sync.sh";
    };
  };
}
