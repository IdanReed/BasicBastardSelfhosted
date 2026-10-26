{ config, pkgs, lib, ... }:

# Authentik (OIDC provider + forward-auth outpost).
#
# Stays containerised, but the compose file ships *in the flake* and is applied
# by a plain systemd unit: deploys happen on `nixos-rebuild switch`, with no
# mutable checkout and no drift window. The compose file lives in /nix/store,
# so the project name MUST be pinned with `-p` — compose would otherwise derive
# it from the store directory, which changes every rebuild and orphans the
# previous containers.

let
  composeDir = ../authentik;
  composeFile = "${composeDir}/compose.yaml";
  projectName = "authentik";

  docker = "${config.virtualisation.docker.package}/bin/docker";
  compose = "${docker} compose -f ${composeFile} -p ${projectName}";
in
{
  # One EnvironmentFile: compose needs several variables at once and
  # sops.secrets.<name> yields one value per file.
  #
  # Every name here is half of the oidc-contract: the other half is the
  # matching worker env in authentik/compose.yaml, consumed by !Env in
  # blueprints/custom/<app>-oidc.yaml.
  sops.templates."authentik.env" = {
    content = ''
      PG_PASS=${config.sops.placeholder.PG_PASS}
      AUTHENTIK_SECRET_KEY=${config.sops.placeholder.AUTHENTIK_SECRET_KEY}
      HEADSCALE_OIDC_CLIENT_SECRET=${config.sops.placeholder.HEADSCALE_OIDC_CLIENT_SECRET}
      IMMICH_OIDC_CLIENT_SECRET=${config.sops.placeholder.IMMICH_OIDC_CLIENT_SECRET}
      OUTLINE_OIDC_CLIENT_SECRET=${config.sops.placeholder.OUTLINE_OIDC_CLIENT_SECRET}
      JELLYFIN_OIDC_CLIENT_SECRET=${config.sops.placeholder.JELLYFIN_OIDC_CLIENT_SECRET}
      KAVITA_OIDC_CLIENT_SECRET=${config.sops.placeholder.KAVITA_OIDC_CLIENT_SECRET}
      ABS_OIDC_CLIENT_SECRET=${config.sops.placeholder.ABS_OIDC_CLIENT_SECRET}
      PAPERLESS_OIDC_CLIENT_SECRET=${config.sops.placeholder.PAPERLESS_OIDC_CLIENT_SECRET}
      BOOKSTACK_OIDC_CLIENT_SECRET=${config.sops.placeholder.BOOKSTACK_OIDC_CLIENT_SECRET}
      HOMEBOX_OIDC_CLIENT_SECRET=${config.sops.placeholder.HOMEBOX_OIDC_CLIENT_SECRET}
      KARAKEEP_OIDC_CLIENT_SECRET=${config.sops.placeholder.KARAKEEP_OIDC_CLIENT_SECRET}
      DAWARICH_OIDC_CLIENT_SECRET=${config.sops.placeholder.DAWARICH_OIDC_CLIENT_SECRET}
      TANDOOR_OIDC_CLIENT_SECRET=${config.sops.placeholder.TANDOOR_OIDC_CLIENT_SECRET}
      MEALIE_OIDC_CLIENT_SECRET=${config.sops.placeholder.MEALIE_OIDC_CLIENT_SECRET}
      VAULTWARDEN_OIDC_CLIENT_SECRET=${config.sops.placeholder.VAULTWARDEN_OIDC_CLIENT_SECRET}
      GHOSTFOLIO_OIDC_CLIENT_SECRET=${config.sops.placeholder.GHOSTFOLIO_OIDC_CLIENT_SECRET}
      ACTUAL_OPENID_CLIENT_SECRET=${config.sops.placeholder.ACTUAL_OPENID_CLIENT_SECRET}
      WEALTHFOLIO_OIDC_CLIENT_SECRET=${config.sops.placeholder.WEALTHFOLIO_OIDC_CLIENT_SECRET}
      EXCALIDRAW_OIDC_CLIENT_SECRET=${config.sops.placeholder.EXCALIDRAW_OIDC_CLIENT_SECRET}
      FORGEJO_OIDC_CLIENT_SECRET=${config.sops.placeholder.FORGEJO_OIDC_CLIENT_SECRET}
      IDAN_INITIAL_PASSWORD=${config.sops.placeholder.IDAN_INITIAL_PASSWORD}
      ALONDRA_INITIAL_PASSWORD=${config.sops.placeholder.ALONDRA_INITIAL_PASSWORD}
      CALE_INITIAL_PASSWORD=${config.sops.placeholder.CALE_INITIAL_PASSWORD}
      ZACH_INITIAL_PASSWORD=${config.sops.placeholder.ZACH_INITIAL_PASSWORD}
      RYLAN_INITIAL_PASSWORD=${config.sops.placeholder.RYLAN_INITIAL_PASSWORD}
      CAMERON_INITIAL_PASSWORD=${config.sops.placeholder.CAMERON_INITIAL_PASSWORD}
      JUSTIN_INITIAL_PASSWORD=${config.sops.placeholder.JUSTIN_INITIAL_PASSWORD}
      AUTHENTIK_BOOTSTRAP_PASSWORD=${config.sops.placeholder.AUTHENTIK_BOOTSTRAP_PASSWORD}
      AUTHENTIK_BOOTSTRAP_TOKEN=${config.sops.placeholder.AUTHENTIK_BOOTSTRAP_TOKEN}
    '';
    mode = "0400";

    # Stable template path: a rotation leaves the unit byte-identical, so
    # nothing restarts without this.
    restartUnits = [ "authentik.service" ];
  };

  # The app OIDC client secrets and the per-user login passwords come from
  # secrets/shared.sops.json (secrets/shared.nix declares them): the services
  # VM renders the SAME value into each app's env, so the two sides cannot
  # drift. Rotate = edit the shared file, switch both hosts, push.
  sops.secrets = {
    PG_PASS = { };
    AUTHENTIK_SECRET_KEY = { };

    HEADSCALE_OIDC_CLIENT_SECRET = { };

    # Without these nobody can log in at all: the blueprint's users have no
    # credential and no SMTP is configured for a reset link. The worker
    # consumes them on first start to create the `akadmin` superuser.
    AUTHENTIK_BOOTSTRAP_PASSWORD = { };
    AUTHENTIK_BOOTSTRAP_TOKEN = { };
  };

  systemd.services.authentik = {
    description = "Authentik identity provider (docker compose)";
    after = [ "docker.service" "docker.socket" "network-online.target" ];
    requires = [ "docker.service" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    # This unit IS authentik's deploy plane, and headscale stays up regardless
    # (only_start_if_oidc_is_available false), so nothing else turns red when
    # login breaks.
    onFailure = [ "notify-failure@%n.service" ];

    # OnFailure only fires once the start limit is exhausted, which the default
    # 5 starts / 10 SECONDS never reaches at RestartSec=30s. 5 × (10min + 30s)
    # ≈ 52min, comfortably inside 4h.
    startLimitIntervalSec = 14400;
    startLimitBurst = 5;

    path = [ config.virtualisation.docker.package ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      EnvironmentFile = config.sops.templates."authentik.env".path;

      # Best effort: a registry outage must not tear down a working deployment
      # or block boot.
      ExecStartPre = "-${compose} pull --quiet";
      ExecStart = "${compose} up -d --remove-orphans --wait";
      ExecStop = "${compose} down";

      # `up -d --wait` blocks until healthchecks pass; postgres alone has a 20s
      # start_period.
      TimeoutStartSec = "10min";

      Restart = "on-failure";
      RestartSec = "30s";
    };
  };
}
