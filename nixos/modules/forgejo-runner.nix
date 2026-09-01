# Forgejo Actions runner — HOST execution only, no container runtime, no
# docker socket. Imported by nixos/configuration.nix.
#
# (Was a sketch until 2026-08-31. It is wired in now because the Renovate work
# needs a runner: renovate.json bumps a compose tag, the `image-pins` lint
# then fails because tests/lib/images.nix still holds the old digest, and
# .forgejo/workflows/renovate-pins.yml is what closes that gap by running
# ./tests/update-images.sh on the PR branch. Without a runner the whole
# Renovate flow produces PRs that can never go green.)
#
# PLACEMENT — this file lives in the services-VM flake, i.e. candidate (a) of
# the two the original sketch laid out. Recorded rather than re-litigated:
#
#   (a) Services VM (here, 10.0.0.3). Always on, same host as Forgejo itself
#       so registration survives tailnet outages, and CI results are where the
#       forge is. Cost: the VM suites peak at several GB of guest RAM apiece
#       on a box sized for production stacks, and a runaway CI build contends
#       with every production container. heavy-nightly's 09:17 UTC slot
#       already dodges the 02:45 backup-prepare window.
#
#   (b) Desktop (nixos-de, 7800X3D/4090). Native KVM, far more RAM, suites
#       finish in a fraction of the time, a wedged qemu hurts nothing. Cost:
#       not always on, so pushes queue until it wakes — fatal for the nightly
#       if it sleeps nights.
#
#   Middle path, still open: import on BOTH, desktop carrying `kvm` and this
#   host carrying only `nix`. Labels are per-instance, so that is two
#   different `labels` lists and nothing else.
#
# The Renovate leg only needs `[self-hosted, nix]` (lints.yml's tier: no VM
# is booted). `kvm` is registered too so suites.yml — which triggers on
# pull_request, i.e. on every Renovate PR — has somewhere to run. If nested
# virtualisation is NOT enabled on the Proxmox host, that is still the better
# failure: the nix daemon does not advertise the `kvm` system feature, and the
# test derivations (which requiredSystemFeatures = ["kvm"]) fail immediately
# with "required system feature not available" instead of falling back to TCG
# and blowing a two-hour timeout. Enable it with VM CPU type "host" and
# nested=1; verify with `ls /dev/kvm` in the guest.

{ config, pkgs, lib, ... }:

let
  # Registration token, decrypted at runtime by ci-secrets.nix from
  # nixos/forgejo-runner.sops.env. The decrypted file is literally `TOKEN=…`,
  # which is exactly the EnvironmentFile shape nixpkgs' module wires into
  # `EnvironmentFile=` and its ExecStartPre reads as $TOKEN — so unlike the
  # earlier sketch there is no sops.templates bridge in the middle.
  #
  # See ci-secrets.nix for why these two credentials are dotenv files rather
  # than keys in nixos/secrets.sops.yaml (short version: adding a key to an
  # already-encrypted sops-yaml needs the age PRIVATE key, and that file now
  # holds two real ssh private keys that a regenerate would destroy).
  tokenFile = "/run/ci-secrets/forgejo-runner-token.env";

  # All `:host`. Matching is superset-style, so `runs-on: [self-hosted, nix]`
  # needs BOTH names registered — `self-hosted` is NOT implicit in Forgejo,
  # unlike GitHub.
  #
  # Changing this list forces a RE-REGISTRATION (the module's ExecStartPre
  # compares a .labels stamp), which needs a valid, unused registration token
  # in nixos/forgejo-runner.sops.env at that moment. Budget for that before
  # editing it.
  labels = [
    "self-hosted:host"
    "nix:host"
    "kvm:host"
  ];
in
{
  assertions = [
    {
      # Idan's non-negotiable, made mechanical. nixpkgs' module derives the
      # container runtime from the LABELS: an empty label list, or any label
      # containing ":docker:", sets wantsContainerRuntime, which adds the
      # runner's DynamicUser to the `docker` group. That group is
      # root-equivalent on this host — it is the same socket Arcane holds and
      # the reason Arcane is the only thing allowed to have it. A future edit
      # that adds a convenience `ubuntu-latest:docker://…` label would grant
      # it silently; this fails the build instead.
      assertion = labels != [ ] && lib.all (l: lib.hasSuffix ":host" l) labels;
      message = ''
        forgejo-runner: every runner label must end in ":host". A ":docker:"
        label (or an empty list, which means the same thing upstream) makes
        nixpkgs' gitea-actions-runner module add the runner to the
        root-equivalent docker group. If a workflow genuinely needs the
        daemon, that is a separate decision — take it in the same commit as
        the workflow, not by editing this list.
      '';
    }
  ];

  # nixpkgs has no separate forgejo-runner service module; the gitea one is
  # the documented way to run it (its own option text says Gitea/Forgejo), and
  # pkgs.forgejo-runner ships an `act_runner` compat symlink precisely so this
  # module's ExecStart finds its binary.
  services.gitea-actions-runner = {
    package = pkgs.forgejo-runner;

    # Instance name becomes the unit name: gitea-runner-forgejo.service.
    instances.forgejo = {
      enable = true;
      name = config.networking.hostName;

      # Through Caddy on the tailnet rather than the loopback publish, even
      # though Forgejo is on this host and Renovate itself takes the short
      # path (nixos/modules/renovate.nix explains why it can). Two reasons the
      # runner cannot: the URL it registers with is baked into
      # /var/lib/gitea-runner/forgejo/.runner and is what actions/checkout
      # resolves the repository against, so a loopback registration would make
      # every job's clone URL host-local and unreproducible if the runner ever
      # moves to the desktop (placement option (b) above, which is still
      # open); and the runner is the one component whose whole job is to talk
      # to the forge the way a client does. Consequence: this host must be ON
      # the tailnet before registration can succeed — the after= on the unit
      # override below waits for tailscale-autoconnect's boot-time run.
      url = "https://forgejo.svc.idanreed.com";

      inherit labels tokenFile;

      # What a workflow's `run:` steps see on PATH. `coreutils` is added by
      # the module unconditionally. This is the upstream default set minus
      # wget, plus what THIS repo's scripts actually call — checked against
      # the scripts, not guessed:
      #
      #   nix              tests/run.sh is nix-build all the way down, and
      #                    tests/update-images.sh shells out to
      #                    `nix run nixpkgs#nix-prefetch-docker`.
      #   util-linux       update-images.sh's single-instance guard is
      #                    `flock -E 99 -w 0` (tests/update-images.sh:47).
      #                    Without it the script dies before it starts.
      #   findutils        the same script's reference collection is
      #                    `find . -name compose.yaml … | xargs -0 grep`.
      #   gnugrep/gnused   that pipeline, plus the digest/hash extraction.
      #   gnutar/gzip/xz   checkout fallbacks, and nix fetchers unpack with
      #                    these.
      #   nodejs           actions/checkout is a JS action even in host mode.
      #   gitMinimal       checkout, and renovate-pins.yml's commit + push.
      #   openssh          nix-build fetchers may go over ssh; harmless
      #                    otherwise.
      #
      # The nix DAEMON does the building, so the runner needs no trusted-user
      # grant and no extra permissions: it is just another daemon client
      # talking to a 0666 socket.
      hostPackages = with pkgs; [
        bash
        coreutils
        curl
        findutils
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
        util-linux
        xz
      ];

      settings = {
        # One job at a time: every VM suite boots multi-GB guests, and two
        # racing melt this host. suites.yml sequences its suites as steps of
        # one job; capacity 1 keeps two workflows from doing in parallel what
        # that sequencing prevents within one.
        runner.capacity = 1;
        # `./tests/run.sh all` cold-builds the world; align with
        # heavy-nightly.yml's 360-minute ceiling rather than act_runner's 3h
        # default.
        runner.timeout = "6h";
      };
    };
  };

  systemd.services.gitea-runner-forgejo = {
    # Boot-time registration resolves the url above over the tailnet, so wait
    # for tailscale-autoconnect's run to complete first. Ordering only, no
    # wants=: autoconnect is a non-RemainAfterExit oneshot in
    # multi-user.target's transaction, so After= waits for its boot run, and
    # the test profiles that pull it out of the target make this edge a no-op
    # rather than dragging the unit back in. Without it, a slow tailnet at
    # boot trips the start limiter in ~10s (see the onFailure note below) and
    # the runner sits `failed` until a manual start.
    after = [ "tailscale-autoconnect.service" ];

    # SKIPPED, not failed, until the registration token exists. Without this
    # the unit would loop: Restart=on-failure with RestartSec=2 trips the
    # default start limiter in ~10s, lands in `failed`, and fires the
    # OnFailure below on every boot for a setup step nobody has done yet.
    # A condition failure is not a failure — the unit simply does not start,
    # and `systemctl --failed` (asserted literally by the services and forgejo
    # suites) stays clean.
    unitConfig.ConditionPathExists = tokenFile;

    # The token file is derived from a store path, so a rotated secret changes
    # ci-secrets.service — but nothing would otherwise restart THIS unit to
    # pick the new value up. (Only matters before first registration: after
    # that act_runner uses .runner and ignores $TOKEN entirely.)
    restartTriggers = [ ../forgejo-runner.sops.env ];

    # Safe to wire, and checked against configuration.nix's notify-failure@
    # header: the rule there is that OnFailure= is dead code on a unit whose
    # RestartSec lets the start limiter's window reset before the burst is
    # reached. Upstream sets Restart=on-failure with RestartSec=2, well under
    # the ~3s line for the default 5-starts-per-10-seconds limiter, so this
    # unit does reach `failed` — in about ten seconds — and the notification
    # actually fires. No StartLimit override needed; adding one here would
    # only lengthen an already-correct loop.
    onFailure = [ "notify-failure@%n.service" ];

    # /dev/kvm: the NixOS test driver runs qemu INSIDE the nix build sandbox,
    # so it is the nix-daemon's build users that need KVM — the daemon maps
    # the device in and advertises the `kvm` system feature automatically when
    # it exists. Nothing to configure beyond the device existing (see the
    # nested-virtualisation note in the header). This supplementary group is
    # only for host-label steps poking qemu directly, e.g. `run.sh debug` by
    # hand; the CI workflows never do.
    serviceConfig.SupplementaryGroups = [ "kvm" ];
  };

  # Deliberately NOT granted: docker. The workflows in .forgejo/workflows/
  # never touch the daemon — see the assertion above, which makes that
  # mechanical rather than a comment. If the caddy-image build ever moves here
  # (ServerNotes/designs/dev-forgejo-ci.md), it needs a decision about the
  # socket, not a quiet edit to the labels list.
}
