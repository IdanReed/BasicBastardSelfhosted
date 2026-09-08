# Forgejo Actions runner — host execution only, no container runtime, no
# docker socket.
#
# Exists for the Renovate flow: a tag bump fails the `image-pins` lint until
# renovate-pins.yml runs ./tests/update-images.sh on the PR branch, so without
# a runner no Renovate PR can go green.
#
# If nested virt is not enabled on the Proxmox host, the nix daemon does not
# advertise the `kvm` system feature and test derivations fail immediately
# instead of falling back to TCG and blowing a two-hour timeout. Enable with VM
# CPU type "host" + nested=1; verify with `ls /dev/kvm` in the guest.

{ config, pkgs, lib, ... }:

let
  # Decrypted at runtime by ci-secrets.nix from nixos/forgejo-runner.sops.env,
  # whose single key is `TOKEN` — the EnvironmentFile shape nixpkgs' module
  # reads.
  tokenFile = "/run/ci-secrets/forgejo-runner-token.env";

  # Matching is superset-style: `runs-on: [self-hosted, nix]` needs BOTH names
  # registered — `self-hosted` is not implicit in Forgejo. Changing this list
  # forces a RE-REGISTRATION (ExecStartPre compares a .labels stamp), which
  # needs a valid, unused registration token at that moment.
  labels = [
    "self-hosted:host"
    "nix:host"
    "kvm:host"
  ];
in
{
  assertions = [
    {
      # nixpkgs' module derives the container runtime from the LABELS: an empty
      # list, or any ":docker:" label, adds the runner's DynamicUser to the
      # root-equivalent `docker` group.
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

  # nixpkgs has no forgejo-runner module; the gitea one is the documented way
  # to run it, and pkgs.forgejo-runner ships an `act_runner` compat symlink so
  # this module's ExecStart finds its binary.
  services.gitea-actions-runner = {
    package = pkgs.forgejo-runner;

    # Instance name becomes the unit name: gitea-runner-forgejo.service.
    instances.forgejo = {
      enable = true;
      name = config.networking.hostName;

      # Through Caddy on the tailnet, not the loopback publish Renovate uses:
      # the registered URL is baked into .runner and is what actions/checkout
      # resolves the repo against. Consequence: this host must be on the
      # tailnet before registration (see the after= below).
      url = "https://forgejo.svc.idanreed.com";

      inherit labels tokenFile;

      # PATH for workflow `run:` steps. The nix DAEMON does the building, so no
      # trusted-user grant is needed — the runner is just another client.
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
        # VM suites boot multi-GB guests; two racing melt this host.
        runner.capacity = 1;
        # Aligned with heavy-nightly.yml's 360-minute ceiling.
        runner.timeout = "6h";
      };
    };
  };

  systemd.services.gitea-runner-forgejo = {
    # Registration resolves the url above over the tailnet. Ordering only, no
    # wants=: autoconnect is a non-RemainAfterExit oneshot and test profiles
    # pull it out of multi-user.target.
    after = [ "tailscale-autoconnect.service" ];

    # Skipped, not failed, until the registration token exists — otherwise
    # RestartSec=2 trips the start limiter and fires OnFailure on every boot.
    unitConfig.ConditionPathExists = tokenFile;

    # A rotated secret changes ci-secrets.service but nothing else would
    # restart this unit to pick it up.
    restartTriggers = [ ../forgejo-runner.sops.env ];

    # Upstream's RestartSec=2 is under the ~3s line for the default limiter, so
    # the unit reaches `failed` and this is not dead code.
    onFailure = [ "notify-failure@%n.service" ];

    # For host-label steps poking qemu directly; the nix daemon maps /dev/kvm
    # for its own build users.
    serviceConfig.SupplementaryGroups = [ "kvm" ];
  };

  # Deliberately NOT granted: docker. The assertion above makes that
  # mechanical.
}
