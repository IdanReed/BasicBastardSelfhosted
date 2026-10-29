# Renovate as a host systemd timer — no container, no docker socket. Weekly:
# checks every pinned image tag against its registry and opens a Forgejo PR per
# outdated dependency. Repo-side config (managers, groups, labels) lives in
# renovate.json; only self-hosted options are here.
#
# Renovate must NEVER merge. Both switches are repo-level in renovate.json and
# both are needed: `automerge` defaults false, but `platformAutomerge` defaults
# TRUE and hands the merge to the forge.

{ config, pkgs, ... }:

let
  envFile = config.sops.templates."renovate.env".path;
in
{
  # The EnvironmentFile shape Renovate reads; the PAT is a sops secret in
  # nixos/secrets.sops.yaml. A switch that changes it reaches the next run.
  sops.templates."renovate.env".content = ''
    RENOVATE_TOKEN=${config.sops.placeholder.RENOVATE_TOKEN}
  '';

  services.renovate = {
    enable = true;

    # 05:20 local is clear of backup-prepare (02:45), the staleness check
    # (12:00) and heavy-nightly's 09:17 UTC, so a CI sweep never competes for
    # the runner.
    schedule = "Mon *-*-* 05:20:00";

    # Runs renovate-config-validator in the derivation, so a bad setting fails
    # the build rather than 05:20 on a Monday. Does NOT cover the repo-side
    # renovate.json — validate that by hand:
    #   nix-shell -p renovate --run "renovate-config-validator renovate.json"
    validateSettings = true;

    settings = {
      platform = "forgejo";
      # Loopback: Renovate runs on the same host as Forgejo. gitUrl =
      # "endpoint" is load-bearing — the default clones repo.clone_url, which
      # would drag tailscaled and Caddy into the dependency set. If Forgejo
      # ever moves off-host, drop gitUrl and use the tailnet vhost.
      endpoint = "http://127.0.0.1:10550/api/v1";
      gitUrl = "endpoint";

      # Not the CI leg's identity (renovate-pins.yml commits as
      # forgejo-actions@): Renovate stops force-pushing over a branch tip it
      # did not author, which is what preserves the CI-authored pin commit.
      gitAuthor = "Renovate Bot <renovate@svc.idanreed.com>";

      # Explicit list, not autodiscovery: the forge also hosts private repos
      # this bot has no business opening PRs on.
      autodiscover = false;
      repositories = [ "idan/BasicBastardSelfhosted" ];

      # "required" makes a missing renovate.json an error rather than running
      # with defaults, which would enable the nix manager (banned).
      onboarding = false;
      requireConfig = "required";
    };
  };

  systemd.services.renovate = {
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      # RENOVATE_TOKEN. Not the module's `credentials` option: that wants a
      # bare value; a dotenv is what the runner's tokenFile needs too.
      EnvironmentFile = envFile;

      # Skipped, not failed, while the PAT is still the changeme_ placeholder —
      # the steady state until the token is minted. A non-zero ExecCondition
      # skips the unit, which keeps `systemctl --failed` clean (the services
      # and forgejo suites assert on that literally). `+` runs it as root (the
      # unit's DynamicUser cannot read the template), and only grep's explicit
      # "no match" (1) lets it start — an unreadable file skips too.
      ExecCondition = "+${pkgs.writeShellScript "renovate-token-set" ''
        ${pkgs.gnugrep}/bin/grep -q '^RENOVATE_TOKEN=changeme_' ${envFile}
        [ $? -eq 1 ]
      ''}";
    };

    # Upstream sets no Restart=, so the unit reaches `failed` on the first bad
    # exit and OnFailure is not dead code.
    onFailure = [ "notify-failure@%n.service" ];
  };

  systemd.timers.renovate.timerConfig = {
    Persistent = true;
    # Registries rate-limit by source IP.
    RandomizedDelaySec = "20m";
  };
}
