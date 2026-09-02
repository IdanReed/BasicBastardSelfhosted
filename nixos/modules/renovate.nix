# Renovate, as a host systemd timer. No container, no docker socket.
#
# Weekly: checks every pinned image tag against its registry, opens a Forgejo
# PR per outdated dependency. NEVER merges — see AUTOMERGE below. Repo-side
# config (managers, groups, labels) is renovate.json; only "self-hosted"
# options live here.
#
# HOST TIMER, NOT A CONTAINER: upstream's containerised recipes mount the
# docker socket for sidecar toolchains; this fleet's hard rule is no socket
# anywhere but Komodo's Periphery, and none of it is needed — the enabled
# managers (docker-compose, dockerfile, custom.regex) are pure text extraction
# plus registry HTTP, and nixpkgs ships a hardened service module
# (DynamicUser, PrivateUsers, empty CapabilityBoundingSet). Closure cost,
# measured: renovate-41.169.3 + nodejs-22, 41.9 MiB download / 328.7 MiB
# unpacked once per machine; the test driver shares the host store, so zero
# per run and zero guest disk.
#
# ENDPOINT: LOOPBACK, NOT THE TAILNET VHOST. Renovate runs on the same host
# as Forgejo (127.0.0.1:10550), so both halves below are load-bearing, checked
# against the 41.169.3 source:
#   * endpoint works with or without the /api/v1 suffix (trimTrailingApiPath
#     in forgejo/utils.ts strips and re-appends it); spelled out per the docs.
#   * gitUrl MUST be "endpoint": getRepoUrl's default uses repo.clone_url,
#     derived from FORGEJO__server__ROOT_URL — cloning over the tailnet and
#     dragging tailscaled + Caddy + the wildcard cert into the dependency set.
#     The "endpoint" branch clones http://127.0.0.1:10550/idan/<repo>.git.
# Plaintext HTTP adds no exposure Caddy's own loopback hop doesn't have.
# FALLBACK if Forgejo moves off-host: drop gitUrl, set endpoint =
# "https://forgejo.svc.idanreed.com/api/v1".
#
# AUTOMERGE — Idan's non-negotiable: Renovate must never merge. Both switches
# are repo-level, in renovate.json, and BOTH are needed: `automerge` defaults
# false, but `platformAutomerge` defaults TRUE and hands the merge to the
# forge's auto-merge-when-checks-pass. Setting only the first would look
# correct and merge anyway.

{ ... }:

{
  services.renovate = {
    enable = true;

    # Weekly — every PR costs Idan a review by design. 05:20 local: clear of
    # backup-prepare (02:45), the backup staleness check (12:00), and
    # heavy-nightly's 09:17 UTC (~03:17/04:17 local), so a full CI sweep never
    # competes with this for the runner.
    schedule = "Mon *-*-* 05:20:00";

    # Fail the BUILD, not at 05:20 on a Monday: runs renovate-config-validator
    # over the generated JSON in the derivation. Does NOT cover the repo-side
    # renovate.json — that would put a ~330 MB node closure into the
    # seconds-long lint tier. Validate that by hand after editing:
    #   nix-shell -p renovate --run "renovate-config-validator renovate.json"
    validateSettings = true;

    settings = {
      platform = "forgejo";
      endpoint = "http://127.0.0.1:10550/api/v1";
      gitUrl = "endpoint";

      # Deliberately NOT the CI leg's identity (renovate-pins.yml commits as
      # forgejo-actions@): Renovate treats a branch tip not authored by
      # gitAuthor as "modified by someone else" and stops force-pushing over
      # it — which is what keeps the CI-authored pin commit from being wiped.
      gitAuthor = "Renovate Bot <renovate@svc.idanreed.com>";

      # Explicit list, not autodiscovery: the forge also hosts ServerNotes and
      # the retired arcane-sops fork.
      autodiscover = false;
      repositories = [ "idan/BasicBastardSelfhosted" ];

      # renovate.json is committed, so onboarding has nothing to propose;
      # "required" makes a MISSING renovate.json an error instead of running
      # with defaults — which would enable every manager, including the nix
      # one that bumps flake inputs (banned; see renovate.json's
      # enabledManagers comment).
      onboarding = false;
      requireConfig = "required";
    };
  };

  systemd.services.renovate = {
    # ci-secrets writes /run/ci-secrets/renovate.env only when the PAT is
    # present and is no longer a changeme_ template.
    after = [
      "ci-secrets.service"
      "network-online.target"
    ];
    wants = [
      "ci-secrets.service"
      "network-online.target"
    ];

    unitConfig = {
      # SKIPPED, not failed, while the PAT is unset — the steady state until
      # Idan mints the token. Keeps `systemctl --failed` clean, which the
      # services and forgejo suites assert on literally.
      ConditionPathExists = "/run/ci-secrets/renovate.env";
    };

    serviceConfig = {
      # RENOVATE_TOKEN. Not the upstream module's `credentials` option: that
      # wants a BARE value, and ci-secrets.nix emits a dotenv (which the
      # runner's tokenFile also needs) — one shape serves both.
      EnvironmentFile = "/run/ci-secrets/renovate.env";
    };

    # CAN fail meaningfully (expired PAT, forge down, registry 500s). Safe per
    # configuration.nix's notify-failure@ header: upstream sets no Restart=,
    # so the unit reaches `failed` on the first bad exit — no StartLimit
    # sizing needed.
    onFailure = [ "notify-failure@%n.service" ];
  };

  systemd.timers.renovate.timerConfig = {
    # A host off on Monday morning still gets its run
    Persistent = true;
    # Registries rate-limit by source IP; a fixed second-of-the-week is a
    # needless thundering-herd signature
    RandomizedDelaySec = "20m";
  };
}
