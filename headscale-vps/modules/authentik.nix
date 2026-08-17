{ config, pkgs, lib, ... }:

# Authentik (OIDC provider for Headscale).
#
# Replaces the former stacks/authentik/ compose stack driven by stack-sync.
# Authentik stays containerised — it is an application with a monthly release
# cadence and DB migrations, so the upstream-supported images are the right
# shape — but the compose file now ships *in the flake* and is applied by a
# plain systemd unit. Consequences:
#
#   - Deploys happen on `nixos-rebuild switch`, not on a git-poll timer.
#     There is no drift window and no mutable checkout on the host.
#   - The unit is the single source of truth: `systemctl restart authentik`
#     re-converges, and systemd restarts it on failure.
#   - The compose file lives in /nix/store (read-only, content-addressed), so
#     the project name must be pinned explicitly. Without `-p`, compose would
#     derive it from the store directory name, which changes on every rebuild
#     and would orphan the previous containers.

let
  composeDir = ../authentik;
  composeFile = "${composeDir}/compose.yaml";
  projectName = "authentik";

  docker = "${config.virtualisation.docker.package}/bin/docker";
  compose = "${docker} compose -f ${composeFile} -p ${projectName}";
in
{
  # Rendered into a single EnvironmentFile because compose needs several
  # variables at once. sops.secrets.<name> yields one value per file, so a
  # template is the right primitive here.
  sops.templates."authentik.env" = {
    content = ''
      PG_PASS=${config.sops.placeholder.PG_PASS}
      AUTHENTIK_SECRET_KEY=${config.sops.placeholder.AUTHENTIK_SECRET_KEY}
      HEADSCALE_OIDC_CLIENT_SECRET=${config.sops.placeholder.HEADSCALE_OIDC_CLIENT_SECRET}
    '';
    mode = "0400";
  };

  sops.secrets = {
    PG_PASS = { };
    AUTHENTIK_SECRET_KEY = { };
  };

  systemd.services.authentik = {
    description = "Authentik identity provider (docker compose)";
    after = [ "docker.service" "docker.socket" "network-online.target" ];
    requires = [ "docker.service" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    path = [ config.virtualisation.docker.package ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      EnvironmentFile = config.sops.templates."authentik.env".path;

      # Pull is best-effort: a registry outage must not tear down a working
      # deployment or block boot.
      ExecStartPre = "-${compose} pull --quiet";
      ExecStart = "${compose} up -d --remove-orphans --wait";
      ExecStop = "${compose} down";

      # `up -d --wait` blocks until healthchecks pass; postgres has a 20s
      # start_period, so allow room without hanging a rebuild indefinitely.
      TimeoutStartSec = "10min";

      Restart = "on-failure";
      RestartSec = "30s";
    };
  };
}
