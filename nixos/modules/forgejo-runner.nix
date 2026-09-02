# Forgejo Actions runner — HOST execution only, no container runtime, no
# docker socket. Imported by nixos/configuration.nix.
#
# Exists for the Renovate flow: a tag bump fails the `image-pins` lint until
# renovate-pins.yml runs ./tests/update-images.sh on the PR branch — without a
# runner, Renovate PRs can never go green.
#
# PLACEMENT — services VM, recorded rather than re-litigated: always on, same
# host as Forgejo (registration survives tailnet outages). Cost: VM suites
# peak at several GB of guest RAM apiece and contend with production
# containers; heavy-nightly's 09:17 UTC dodges the 02:45 backup-prepare
# window. Alternative (b), the desktop (nixos-de): faster, but not always on —
# pushes queue until it wakes. Middle path still open: import on BOTH with
# per-instance `labels` lists (desktop `kvm`, this host `nix`).
#
# The Renovate leg only needs `[self-hosted, nix]`; `kvm` is registered so
# suites.yml (pull_request → every Renovate PR) has somewhere to run.
# ⚠ If nested virt is NOT enabled on the Proxmox host, that is still the
# better failure: the nix daemon does not advertise the `kvm` system feature,
# so test derivations (requiredSystemFeatures = ["kvm"]) fail immediately
# instead of falling back to TCG and blowing a two-hour timeout. Enable with
# VM CPU type "host" + nested=1; verify with `ls /dev/kvm` in the guest.

{ config, pkgs, lib, ... }:

let
  # Registration token, decrypted at runtime by ci-secrets.nix from
  # nixos/forgejo-runner.sops.env — literally `TOKEN=…`, the EnvironmentFile
  # shape nixpkgs' module reads as $TOKEN. See ci-secrets.nix for why dotenv
  # rather than a key in nixos/secrets.sops.yaml.
  tokenFile = "/run/ci-secrets/forgejo-runner-token.env";

  # All `:host`. Matching is superset-style: `runs-on: [self-hosted, nix]`
  # needs BOTH names registered — `self-hosted` is NOT implicit in Forgejo,
  # unlike GitHub.
  # ⚠ Changing this list forces a RE-REGISTRATION (ExecStartPre compares a
  # .labels stamp), which needs a valid, unused registration token in
  # nixos/forgejo-runner.sops.env at that moment.
  labels = [
    "self-hosted:host"
    "nix:host"
    "kvm:host"
  ];
in
{
  assertions = [
    {
      # 🚨 Idan's non-negotiable, made mechanical. nixpkgs' module derives the
      # container runtime from the LABELS: an empty list, or any ":docker:"
      # label, adds the runner's DynamicUser to the root-equivalent `docker`
      # group — the socket only Komodo's Periphery may hold. A convenience
      # `ubuntu-latest:docker://…` label would grant it silently; this fails
      # the build instead.
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

      # Through Caddy on the tailnet, NOT the loopback publish Renovate takes
      # (renovate.nix explains why it can): the registered URL is baked into
      # /var/lib/gitea-runner/forgejo/.runner and is what actions/checkout
      # resolves the repo against, so a loopback registration breaks every
      # job's clone URL if the runner ever moves to the desktop (option (b),
      # still open). Consequence: this host must be ON the tailnet before
      # registration — hence the after= on the unit override below.
      url = "https://forgejo.svc.idanreed.com";

      inherit labels tokenFile;

      # PATH for workflow `run:` steps (`coreutils` added unconditionally by
      # the module): upstream default set minus wget, plus what this repo's
      # scripts actually call — checked, not guessed:
      #   nix              tests/run.sh is nix-build all the way down;
      #                    update-images.sh runs `nix run nixpkgs#nix-prefetch-docker`
      #   util-linux       update-images.sh's `flock -E 99 -w 0` guard
      #                    (tests/update-images.sh:47)
      #   findutils        its `find … | xargs -0 grep` reference collection
      #   gnugrep/gnused   that pipeline, plus digest/hash extraction
      #   gnutar/gzip/xz   checkout fallbacks; nix fetchers unpack with these
      #   nodejs           actions/checkout is a JS action even in host mode
      #   gitMinimal       checkout, and renovate-pins.yml's commit + push
      #   openssh          nix-build fetchers may go over ssh
      # The nix DAEMON does the building, so no trusted-user grant is needed:
      # the runner is just another daemon client on a 0666 socket.
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
        # One job at a time: VM suites boot multi-GB guests, and two racing
        # melt this host — capacity 1 extends suites.yml's within-job
        # sequencing across workflows.
        runner.capacity = 1;
        # `run.sh all` cold-builds the world; align with heavy-nightly.yml's
        # 360-minute ceiling rather than act_runner's 3h default.
        runner.timeout = "6h";
      };
    };
  };

  systemd.services.gitea-runner-forgejo = {
    # Registration resolves the url above over the tailnet, so wait for
    # tailscale-autoconnect's boot run. Ordering only, no wants=: autoconnect
    # is a non-RemainAfterExit oneshot in multi-user.target's transaction, and
    # test profiles that pull it out of the target make this edge a no-op.
    # Without it, a slow tailnet at boot trips the start limiter in ~10s and
    # the runner sits `failed` until a manual start.
    after = [ "tailscale-autoconnect.service" ];

    # SKIPPED, not failed, until the registration token exists — otherwise
    # Restart=on-failure/RestartSec=2 trips the start limiter in ~10s and
    # fires OnFailure on every boot for a setup step nobody has done yet.
    # Keeps `systemctl --failed` clean (asserted literally by the services and
    # forgejo suites).
    unitConfig.ConditionPathExists = tokenFile;

    # A rotated secret changes ci-secrets.service, but nothing else would
    # restart THIS unit to pick it up. (Only matters before first
    # registration: after that act_runner uses .runner and ignores $TOKEN.)
    restartTriggers = [ ../forgejo-runner.sops.env ];

    # Checked against configuration.nix's notify-failure@ header: upstream's
    # RestartSec=2 is under the ~3s line for the default 5-starts-per-10s
    # limiter, so the unit reaches `failed` in ~10s and the notification
    # fires. No StartLimit override needed.
    onFailure = [ "notify-failure@%n.service" ];

    # /dev/kvm: the test driver runs qemu INSIDE the nix build sandbox, so it
    # is the nix-daemon's build users that need KVM — the daemon maps the
    # device and advertises the `kvm` feature automatically when it exists.
    # This group is only for host-label steps poking qemu directly (e.g.
    # `run.sh debug` by hand); the CI workflows never do.
    serviceConfig.SupplementaryGroups = [ "kvm" ];
  };

  # Deliberately NOT granted: docker — the workflows never touch the daemon,
  # and the assertion above makes that mechanical. If the caddy-image build
  # ever moves here (ServerNotes/designs/dev-forgejo-ci.md), that is a
  # decision about the socket, not a quiet edit to the labels list.
}
