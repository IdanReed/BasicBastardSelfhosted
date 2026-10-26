# Forgejo, the git root, run from the flake (docker compose).
#
# Not a Komodo stack: Komodo deploys every stack FROM this server, so it can
# neither bring Forgejo up on a fresh host nor recover it from a bad change —
# a push that breaks Forgejo could not be fixed by another push. It ships with
# `nixos-rebuild switch`, like Komodo itself (deploy-plane.nix).

{ config, ... }:

let
  docker = "${config.virtualisation.docker.package}/bin/docker";
  # The whole directory: compose.yaml bind-mounts ./forgejo-init.sh.
  compose = "${docker} compose -f ${../../forgejo}/compose.yaml -p forgejo --env-file /run/stack-env/forgejo.env";
in
{
  # A changed OIDC secret re-runs `up -d`, which recreates forgejo_init so it
  # re-seeds the auth source with the new value.
  sops.templates."stacks/forgejo.env".restartUnits = [ "forgejo.service" ];

  systemd.services.forgejo = {
    description = "Forgejo, the git root (docker compose from the flake)";
    # forgejo joins `homelab` so Komodo can clone from it and receive its webhook.
    after = [ "docker.service" "network-online.target" "stack-env-publish.service" "docker-network-homelab.service" ];
    wants = [ "network-online.target" ];
    requires = [ "docker.service" "stack-env-publish.service" "docker-network-homelab.service" ];
    wantedBy = [ "multi-user.target" ];

    # Forgejo down = no deploys, no Renovate, no CI, and nothing else turns red.
    onFailure = [ "notify-failure@%n.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    # From the store, project name pinned (the store path changes every
    # rebuild). A changed compose.yaml changes this script, so a switch re-runs
    # it.
    script = ''
      ${compose} up -d --remove-orphans
    '';
  };
}
