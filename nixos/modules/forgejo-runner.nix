# Forgejo Actions runner — SKETCH ONLY, NOT IMPORTED ANYWHERE YET.
#
# Nothing references this file: nixos/flake.nix builds configuration.nix
# without it, and no lint or suite covers it. It exists so the runner half of
# the Forgejo CI plan (LONGRUN Phase 3; .forgejo/workflows/*) is written down
# and reviewable before a live forge exists to register against. Wiring it in
# is one line in nixos/flake.nix's module list — but see PLACEMENT below
# first, because "which host imports this" is the actual open decision.
#
# PLACEMENT — open decision for Idan, both candidates sketched here:
#
#   (a) Services VM (this flake, 10.0.0.3). Always on, same host as Forgejo
#       itself so registration survives tailnet outages, and CI results are
#       where the forge is. BUT: the `kvm` label needs nested virtualisation
#       enabled on the Proxmox host (VM CPU type "host" + nested=1), the VM
#       suites peak at several GB of guest RAM apiece on a VM sized for
#       production stacks, and a runaway CI build contends with every
#       production container. The heavy-nightly sweep on this box also
#       brushes the 02:45 backup-prepare window (its cron dodges it).
#
#   (b) Desktop (nixos-de/, 7800X3D/4090). Native KVM, far more RAM/cores,
#       suites finish in a fraction of the time, and a wedged qemu hurts
#       nothing in production. BUT: not always on, so pushes while it sleeps
#       queue until it wakes (fine for a one-person forge, fatal for the
#       nightly if it sleeps nights), and nixos-de tracks nixos-unstable —
#       harmless for the runner itself (it only needs nix + the daemon), but
#       this file would move to nixos-de/modules/nixos/ and lose the sops
#       wiring below in favour of that flake's (currently commented-out)
#       sops setup.
#
#   Middle path: import on BOTH, desktop carrying `kvm` and the VM carrying
#   only `nix` — lints always run, VM suites run when the desktop is awake.
#   Labels are per-instance, so that is just two different `labels` lists.
#
# The module below is written for candidate (a); (b) differs only in where
# the token secret comes from.

{ config, pkgs, ... }:

{
  # Registration token, via the same sops-yaml path as every other OS secret
  # on this host (see configuration.nix for why yaml, not dotenv).
  #
  # PLACEHOLDER: add to nixos/secrets.sops.yaml{,.example} when this module
  # is wired in —
  #
  #   # Runner registration token. Generate in Forgejo:
  #   #   Site administration -> Actions -> Runners -> Create new runner
  #   # (a site-wide token; use a repo-level one to scope the runner down).
  #   FORGEJO_RUNNER_TOKEN: changeme_forgejo_runner_token
  #
  # The token is one-shot: it registers, then .runner (under
  # /var/lib/gitea-runner) holds the real credential. Rotating the sops value
  # forces nothing by itself — the ExecStartPre only re-registers when
  # .runner is missing or the labels changed.
  sops.secrets.FORGEJO_RUNNER_TOKEN = { };

  # tokenFile wants an EnvironmentFile containing `TOKEN=…`, but the per-key
  # sops secret file holds the bare value — bridge with a template.
  sops.templates."forgejo-runner-token.env" = {
    content = "TOKEN=${config.sops.placeholder.FORGEJO_RUNNER_TOKEN}";
    restartUnits = [ "gitea-runner-forgejo.service" ];
  };

  # nixpkgs has no separate forgejo-runner service module; the gitea one is
  # the documented way to run it (the option text itself says Gitea/Forgejo),
  # and pkgs.forgejo-runner ships an `act_runner` compat symlink precisely so
  # this module's ExecStart finds its binary.
  services.gitea-actions-runner = {
    package = pkgs.forgejo-runner;

    # Instance name becomes the unit name: gitea-runner-forgejo.service.
    instances.forgejo = {
      enable = true;
      name = config.networking.hostName;

      # Through Caddy on the tailnet, like every other service. Two
      # consequences: the runner host must be ON the tailnet before the unit
      # can register (tailscale-autoconnect orders itself, but first boot
      # with a changeme token will loop — the unit retries on-failure), and
      # the TLS cert is the real wildcard, so no CA trust fiddling.
      url = "https://forgejo.svc.idanreed.com";

      tokenFile = config.sops.templates."forgejo-runner-token.env".path;

      # All `:host` — jobs run directly on this NixOS host, no job
      # containers (a nix-in-docker runner needs a privileged store mount;
      # pointless when the host is NixOS). Matching is superset-style, so
      # `runs-on: [self-hosted, nix, kvm]` needs ALL THREE names registered —
      # `self-hosted` is NOT implicit in Forgejo, unlike GitHub.
      #
      # Cost note: changing this list forces a re-registration (the module's
      # ExecStartPre compares a .labels stamp), which needs a valid token in
      # sops at that moment.
      #
      # For placement (b)/(both), drop "kvm" on the host that lacks it and
      # keep workflows label-matched — they never name a runner.
      labels = [
        "self-hosted:host"
        "nix:host"
        "kvm:host"
      ];

      # What the workflows' `run:` steps see on PATH (plus coreutils, which
      # the module always adds). The default set minus wget, plus:
      #   nix        — tests/run.sh is nix-build/nix all the way down
      #   nodejs     — actions/checkout is a JS action even in host mode
      #   openssh    — nix-build fetchers may go over ssh; harmless otherwise
      #   gnutar/gzip/xz — checkout fallbacks and nix fetchers unpack with these
      # The nix daemon does the actual building, so no trusted-user grant and
      # no extra permissions: the runner is just another daemon client.
      hostPackages = with pkgs; [
        bash
        coreutils
        curl
        gawk
        gitMinimal
        gnugrep
        gnused
        gnutar
        gzip
        jq
        nix
        nodejs
        openssh
        xz
      ];

      settings = {
        # One job at a time: every suite boots multi-GB guests, and two
        # suites racing melt either candidate host. Sequencing inside a job
        # (suites.yml uses steps) plus capacity 1 across jobs keeps CI to one
        # qemu swarm at a time.
        runner.capacity = 1;
        # `./tests/run.sh all` cold-builds the world; align with
        # heavy-nightly.yml's 360-minute ceiling rather than act_runner's
        # 3h default.
        runner.timeout = "6h";
      };
    };
  };

  # /dev/kvm: the NixOS test driver runs qemu INSIDE the nix build sandbox,
  # so it is the nix-daemon's build users that need KVM — the daemon maps
  # /dev/kvm into the sandbox and advertises the `kvm` system feature
  # automatically when the device exists. Nothing to configure here beyond
  # the device existing, which on the services VM means enabling nested
  # virtualisation on the Proxmox host FIRST (cpu type "host"; check with
  # `ls /dev/kvm` in the guest). The supplementary group below is only for
  # host-label steps poking qemu directly (e.g. `run.sh debug` by hand);
  # the CI workflows never do.
  systemd.services.gitea-runner-forgejo.serviceConfig.SupplementaryGroups = [ "kvm" ];

  # Deliberately NOT granted: docker. The workflows in .forgejo/workflows/
  # never touch the daemon, and the docker group is root-equivalent — if the
  # caddy-image build moves here (ServerNotes/designs/dev-forgejo-ci.md), add
  # "docker" to SupplementaryGroups in the same commit as that workflow, not
  # before.
}
