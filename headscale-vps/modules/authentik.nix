{ config, pkgs, lib, ... }:

# Authentik (OIDC provider for Headscale).
#
# Stays containerised — monthly release cadence + DB migrations make the
# upstream images the right shape — but the compose file ships *in the flake*
# and is applied by a plain systemd unit: deploys happen on `nixos-rebuild
# switch` (no drift window, no mutable checkout), and `systemctl restart
# authentik` re-converges. The compose file lives in /nix/store, so the
# project name MUST be pinned with `-p`: compose would otherwise derive it
# from the store directory name, which changes every rebuild and orphans the
# previous containers.

let
  composeDir = ../authentik;
  composeFile = "${composeDir}/compose.yaml";
  projectName = "authentik";

  docker = "${config.virtualisation.docker.package}/bin/docker";
  compose = "${docker} compose -f ${composeFile} -p ${projectName}";
in
{
  # One EnvironmentFile: compose needs several variables at once, and
  # sops.secrets.<name> yields one value per file — so a template.
  sops.templates."authentik.env" = {
    content = ''
      PG_PASS=${config.sops.placeholder.PG_PASS}
      AUTHENTIK_SECRET_KEY=${config.sops.placeholder.AUTHENTIK_SECRET_KEY}
      HEADSCALE_OIDC_CLIENT_SECRET=${config.sops.placeholder.HEADSCALE_OIDC_CLIENT_SECRET}
      IMMICH_OIDC_CLIENT_SECRET=${config.sops.placeholder.IMMICH_OIDC_CLIENT_SECRET}
      AUTHENTIK_BOOTSTRAP_PASSWORD=${config.sops.placeholder.AUTHENTIK_BOOTSTRAP_PASSWORD}
      AUTHENTIK_BOOTSTRAP_TOKEN=${config.sops.placeholder.AUTHENTIK_BOOTSTRAP_TOKEN}
    '';
    mode = "0400";

    # Stable template path: rotation leaves the unit byte-identical, so
    # nothing restarts without this. The case that bites: a rotated
    # HEADSCALE_OIDC_CLIENT_SECRET reaching the blueprint but not Headscale.
    restartUnits = [ "authentik.service" ];
  };

  sops.secrets = {
    PG_PASS = { };
    AUTHENTIK_SECRET_KEY = { };

    # Consumed by !Env in blueprints/custom/immich-oidc.yaml; the worker is
    # its only VPS-side consumer. The other copy lives in
    # stacks/immich/.sops.env (rendered into immich.json) — rotate both
    # together: restartUnits re-applies the blueprint, the immich stack needs
    # a re-up.
    IMMICH_OIDC_CLIENT_SECRET = { };

    # First-start creation of the `akadmin` superuser + API token. Without
    # these the blueprint's `idan` user has no credential and no SMTP reset
    # path exists — nobody could log in at all.
    AUTHENTIK_BOOTSTRAP_PASSWORD = { };
    AUTHENTIK_BOOTSTRAP_TOKEN = { };
  };

  systemd.services.authentik = {
    description = "Authentik identity provider (docker compose)";
    after = [ "docker.service" "docker.socket" "network-online.target" ];
    requires = [ "docker.service" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    # This unit IS authentik's deploy plane: `up -d --wait` failing means the
    # identity provider is down or mid-migration — "login is broken" — while
    # headscale stays happily up (only_start_if_oidc_is_available false), so
    # nothing else turns red. Fires only once the restart limit is exhausted:
    # intended — a transient the next retry fixes is not phone-worthy.
    onFailure = [ "notify-failure@%n.service" ];

    # Without these OnFailure would NEVER fire: `failed` is only entered when
    # the start-rate limit is exceeded, and the default 5 starts / 10 SECONDS
    # is unreachable with RestartSec=30s — forever "activating". A general
    # trap for every Restart=on-failure + slow-RestartSec unit in the fleet.
    #
    # 5 attempts / 4h: worst case 5 × (10min TimeoutStartSec + 30s) ≈ 52min,
    # comfortably inside 4h, so the limit is genuinely reached. Generous on
    # purpose — a converge needing three tries on a slow boot must not become
    # a phone alert, and the containers carry `restart: unless-stopped`
    # underneath. Eventually giving up is the point.
    startLimitIntervalSec = 14400;
    startLimitBurst = 5;

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
