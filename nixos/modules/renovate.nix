# Renovate, as a host systemd timer. No container, no docker socket.
#
# WHAT IT DOES: once a week it reads every compose file and the caddy
# Dockerfile in this repo, checks each pinned image tag against its registry,
# and opens a Forgejo PR per outdated dependency on a `renovate/**` branch.
# It NEVER merges — see AUTOMERGE below. The repo-side half of the config
# (which managers, which groups, which labels) is renovate.json at the repo
# root; only the things Renovate calls "self-hosted" options live here.
#
# ---------------------------------------------------------------------------
# WHY A HOST TIMER AND NOT A CONTAINER
# ---------------------------------------------------------------------------
# Every containerised Renovate recipe upstream publishes mounts the docker
# socket so the "docker" binarySource can run sidecar toolchains. This fleet's
# hard rule is no socket anywhere but Arcane, and none of it is needed: the
# managers enabled in renovate.json (docker-compose, dockerfile, custom.regex)
# are pure text extraction plus registry HTTP. pkgs.renovate is 41.169.3 in
# nixos-25.11, and nixpkgs already ships a hardened service module for it
# (DynamicUser, PrivateUsers, an empty CapabilityBoundingSet), so the whole
# thing is a settings block.
#
# Closure cost, measured rather than guessed: enabling this adds
# renovate-41.169.3 plus nodejs-22 to the services-VM closure, which every VM
# suite that builds this host now has to realise. Substituted from
# cache.nixos.org it is 41.9 MiB of download / 328.7 MiB unpacked, once per
# machine — the NixOS test driver shares the host store with the guests, so it
# costs nothing per run and nothing in guest disk.
#
# ---------------------------------------------------------------------------
# ENDPOINT: LOOPBACK, NOT THE TAILNET VHOST
# ---------------------------------------------------------------------------
# Forgejo publishes 127.0.0.1:10550 (stacks/forgejo/compose.yaml) and Caddy
# reverse-proxies forgejo.svc.idanreed.com to that same port. Renovate runs on
# THIS host, so it can take the short path, and does:
#
#   endpoint = http://127.0.0.1:10550/api/v1
#   gitUrl   = "endpoint"
#
# Both halves are load-bearing and both were checked against the pinned
# version's source, not assumed:
#
#   * The API base is fine with or without the suffix — forgejo/utils.ts
#     (41.169.3) does `url?.replace(regEx(/api\/v1\/?$/g), '')` in
#     trimTrailingApiPath and re-appends `api/v1` itself. It is spelled out
#     here anyway because the docs specify it and a reader should not have to
#     go find that function.
#
#   * gitUrl MUST be "endpoint". The default branch of getRepoUrl uses
#     `repo.clone_url`, which Forgejo derives from FORGEJO__server__ROOT_URL
#     (= https://forgejo.svc.idanreed.com/) — so leaving it default would
#     authenticate over loopback and then clone over the tailnet, dragging
#     tailscaled + Caddy + the wildcard certificate back into the dependency
#     set for nothing. The "endpoint" branch instead does
#     `url.pathname = `${url.pathname}${repo.full_name}.git`` against the
#     ALREADY-TRIMMED endpoint, i.e. http://127.0.0.1:10550/idan/<repo>.git.
#
# What that buys: a weekly job that keeps working when the tailnet is down,
# when DNS is unhappy, or when the DNS-01 wildcard renewal has lapsed — none
# of which have anything to do with reading image tags. Plaintext HTTP is not
# a downgrade: Caddy reaches Forgejo over the identical unencrypted loopback
# hop, so this adds no exposure that the current design does not already have.
#
# FALLBACK, if Forgejo ever moves off this host: delete the gitUrl line and
# set endpoint = "https://forgejo.svc.idanreed.com/api/v1". Nothing else
# changes; that combination is the ordinary supported configuration.
#
# ---------------------------------------------------------------------------
# AUTOMERGE — Idan's non-negotiable
# ---------------------------------------------------------------------------
# Renovate must never merge. Both switches live in renovate.json (they are
# repo-level options, not self-hosted ones) and BOTH are needed:
# `automerge` defaults to false already, but `platformAutomerge` defaults to
# TRUE, and with it on Renovate hands the merge to the forge's own
# auto-merge-when-checks-pass feature. Setting only the first would look
# correct and merge anyway. See the comment on those two keys in
# renovate.json.

{ ... }:

{
  services.renovate = {
    enable = true;

    # Weekly. Image tags do not move fast enough to want a daily PR flood on a
    # forge with one reviewer, and every PR here costs Idan a review by design.
    # 05:20 local: clear of backup-prepare (02:45), of the backup staleness
    # check (12:00), and of heavy-nightly's 09:17 UTC (~03:17/04:17 local) —
    # so a full CI sweep is never competing with this for the runner.
    schedule = "Mon *-*-* 05:20:00";

    # Fail the BUILD on a malformed settings block rather than at 05:20 on a
    # Monday: the module runs renovate-config-validator over the generated
    # JSON as part of the derivation, so a bad option name or enum value stops
    # `nixos-rebuild` (and `run.sh services`, and the proxmox image gate).
    #
    # It is the only mechanical check the settings below have. Note what it
    # does NOT cover: the repo-side renovate.json is validated by nothing in
    # this harness, because doing so would put a ~330 MB node closure into the
    # seconds-long lint tier. Validate it by hand after editing:
    #   nix-shell -p renovate --run "renovate-config-validator renovate.json"
    validateSettings = true;

    settings = {
      platform = "forgejo";
      endpoint = "http://127.0.0.1:10550/api/v1";
      gitUrl = "endpoint";

      # The identity on Renovate's own commits. It is NOT the identity the CI
      # leg commits under (.forgejo/workflows/renovate-pins.yml uses
      # forgejo-actions@svc.idanreed.com): Renovate treats a branch whose tip
      # is not authored by gitAuthor as "modified by someone else" and stops
      # force-pushing over it, which is exactly the behaviour that keeps the
      # CI-authored pin commit from being wiped on the next run.
      gitAuthor = "Renovate Bot <renovate@svc.idanreed.com>";

      # Explicit list, not autodiscovery. The forge also hosts ServerNotes
      # (prose, no dependencies) and the retired arcane-sops fork, and opening
      # PRs against a repo CLAUDE.md says not to extend would be worse than
      # useless. Adding a repo here is a one-line deploy.
      autodiscover = false;
      repositories = [ "idan/BasicBastardSelfhosted" ];

      # No onboarding PR: renovate.json is already committed at the repo root,
      # so the onboarding flow has nothing to propose. requireConfig
      # "required" then makes a MISSING renovate.json an error instead of
      # silently running with defaults — and defaults would enable every
      # manager, including the nix one that would start bumping flake inputs
      # (see renovate.json's enabledManagers comment for why that is banned).
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
      # SKIPPED, not failed, while the PAT is unset. Before Idan mints the
      # token in Forgejo this is the steady state, and a weekly ntfy push
      # about a known-pending setup step is noise, not signal. systemd logs
      # "Condition check resulted in ... being skipped" and the unit stays
      # inactive — so `systemctl --failed` stays clean, which the services and
      # forgejo suites assert on literally.
      ConditionPathExists = "/run/ci-secrets/renovate.env";
    };

    serviceConfig = {
      # RENOVATE_TOKEN, read by PID 1 as root before the unit drops to its
      # DynamicUser. The upstream module's `credentials` option is the more
      # idiomatic route, but it wants a file holding the BARE value and
      # ci-secrets.nix produces a dotenv (which is what the runner's tokenFile
      # needs, and what the sops CLI emits) — so one shape serves both.
      EnvironmentFile = "/run/ci-secrets/renovate.env";
    };

    # This one CAN fail meaningfully: an expired PAT, a forge that is down, a
    # registry that 500s. Safe to wire per configuration.nix's notify-failure@
    # header — the upstream module sets no Restart=, so the unit reaches
    # `failed` on the first bad exit and needs no StartLimit sizing.
    onFailure = [ "notify-failure@%n.service" ];
  };

  systemd.timers.renovate.timerConfig = {
    # A host that was off on Monday morning should still get its run, rather
    # than skipping a week silently.
    Persistent = true;
    # Nothing else is scheduled here, but registries rate-limit by source IP
    # and a fixed second-of-the-week is a needless thundering-herd signature.
    RandomizedDelaySec = "20m";
  };
}
