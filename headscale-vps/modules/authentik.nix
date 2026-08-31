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
      IMMICH_OIDC_CLIENT_SECRET=${config.sops.placeholder.IMMICH_OIDC_CLIENT_SECRET}
      AUTHENTIK_BOOTSTRAP_PASSWORD=${config.sops.placeholder.AUTHENTIK_BOOTSTRAP_PASSWORD}
      AUTHENTIK_BOOTSTRAP_TOKEN=${config.sops.placeholder.AUTHENTIK_BOOTSTRAP_TOKEN}
    '';
    mode = "0400";

    # sops-nix renders templates to a stable path, so rotating a value leaves
    # the systemd unit byte-identical and nothing would restart. Rotating
    # HEADSCALE_OIDC_CLIENT_SECRET is the case that bites: Authentik's
    # blueprint picks up the new value while Headscale keeps the old one.
    restartUnits = [ "authentik.service" ];
  };

  sops.secrets = {
    PG_PASS = { };
    AUTHENTIK_SECRET_KEY = { };

    # Consumed by !Env in blueprints/custom/immich-oidc.yaml. Unlike
    # HEADSCALE_OIDC_CLIENT_SECRET (declared in headscale.nix because
    # headscale reads its path directly), the worker is this secret's ONLY
    # VPS-side consumer — the other copy lives in stacks/immich/.sops.env,
    # where immich-config-init renders it into immich.json. Rotate both
    # together (restartUnits above re-applies the blueprint; the immich stack
    # needs a re-up so config-init re-renders).
    IMMICH_OIDC_CLIENT_SECRET = { };

    # Without these the blueprint creates user `idan` with no credential, and
    # with no SMTP configured there is no password-reset path either — nobody
    # could log in at all. The worker consumes them on first start to create
    # the `akadmin` superuser and an API token.
    AUTHENTIK_BOOTSTRAP_PASSWORD = { };
    AUTHENTIK_BOOTSTRAP_TOKEN = { };
  };

  systemd.services.authentik = {
    description = "Authentik identity provider (docker compose)";
    after = [ "docker.service" "docker.socket" "network-online.target" ];
    requires = [ "docker.service" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    # This unit IS the deploy plane for authentik: `up -d --wait` failing means
    # a rebuild left the identity provider down or mid-migration, which
    # presents to users as "login is broken" and to headscale as OIDC
    # discovery failing — and because oidc.only_start_if_oidc_is_available is
    # false (modules/headscale.nix) headscale itself stays happily up, so
    # nothing else in the fleet turns red. Silent by construction until now.
    #
    # Restart=on-failure below means this fires only once the restart limit is
    # exhausted and systemd puts the unit in `failed` — that is intended: a
    # single transient pull/healthcheck failure that the next retry fixes is
    # not worth a phone notification.
    onFailure = [ "notify-failure@%n.service" ];

    # Without these, OnFailure above would NEVER fire. systemd only enters the
    # `failed` state — the state OnFailure keys on — when the start-rate limit
    # is exceeded, and its defaults are 5 starts per 10 SECONDS
    # (DefaultStartLimitIntervalSec/DefaultStartLimitBurst), while RestartSec
    # below is 30s: attempts can never accumulate inside a 10s window, so the
    # unit retries forever, stays permanently "activating", and the notifier
    # sits unused. This is a general trap for every `Restart=on-failure` +
    # slow-`RestartSec` unit in the fleet, not a quirk of this one.
    #
    # 5 attempts over a 4h window: worst case is 5 × (10min TimeoutStartSec +
    # 30s) ≈ 52min, comfortably inside 4h, so the limit is genuinely reached
    # and the unit really does fail. Generous rather than tight on purpose —
    # a converge that needs three tries during a slow boot must not be turned
    # into a phone alert, and the containers carry their own
    # `restart: unless-stopped` underneath this. Eventually giving up is the
    # point: an unattended infinite retry is exactly what made this silent.
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
