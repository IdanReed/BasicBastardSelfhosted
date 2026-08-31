# Test harness for BasicBastardSelfhosted.
#
# Deliberately NOT a flake. Flakes only see git-tracked files, so every edit to
# an untracked module — which is most of them while a change is in progress —
# would need a `git add` before it could be tested, and every host-config edit
# would need a re-lock if the host directories were path inputs. Plain Nix has
# neither problem: relative paths just work, and iteration is instant.
#
# nixpkgs is pinned from headscale-vps/flake.lock (see lib/sources.nix), so the
# suites evaluate against exactly the nixpkgs the hosts are built with.
#
# Usage:
#   ./tests/run.sh lints           # pure contract checks, seconds
#   ./tests/run.sh vps             # VPS: caddy + headscale + real tailnet
#   ./tests/run.sh services        # services VM: arcane + stacks
#   ./tests/run.sh tailnet         # both hosts, one tailnet, end to end
#   ./tests/run.sh all
#
# Debugging a failure interactively:
#   nix-build tests -A driver.vps && ./result/bin/nixos-test-driver
#   >>> start_all(); vps.shell_interact()

{
  system ? builtins.currentSystem,
}:

let
  sources = import ./lib/sources.nix { lockFile = ../headscale-vps/flake.lock; };

  pkgs = import sources.nixpkgs { inherit system; };
  lib = pkgs.lib;

  images = import ./lib/images.nix;

  profiles = import ./lib/profiles.nix {
    inherit lib;
    testKeyFile = ./keys/test-age-key.txt;
  };

  sopsModule = "${sources.sops-nix}/modules/sops";

  # The ACME server from nixpkgs' own test suite: Pebble with a fixed CA whose
  # certificate is exposed as config.test-support.acme.caCert. Using it means
  # Caddy runs its real ACME client against a real ACME server over HTTP-01,
  # rather than having certificates handed to it.
  acmeServerModule = "${sources.nixpkgs}/nixos/tests/common/acme/server";

  # ---------------------------------------------------------------------------
  # Production configurations, evaluated for the lints
  # ---------------------------------------------------------------------------
  # These are the *real* values — no test overrides — so lints can assert
  # contracts the VM suites necessarily override away (server_url, the OIDC
  # issuer, the production sops file).
  evalHost =
    modules:
    (import "${sources.nixpkgs}/nixos/lib/eval-config.nix" {
      inherit system;
      modules = modules ++ [
        # Keeps evaluation from demanding a bootloader device or real disks.
        # Nothing the lints read is affected by it.
        { boot.loader.grub.enable = false; }
      ];
    }).config;

  # The VPS module list, mirrored by hand from headscale-vps/flake.nix (the
  # harness cannot import the flake — see the not-a-flake rationale above).
  # A module added to the flake but not here would be deployed yet invisible
  # to every lint, so lints.nix cross-checks this list against the flake's
  # text (module-list-parity) — keep it as relative-path strings so the lint
  # can compare it verbatim. disk-config.nix is deliberately absent: it needs
  # disko's module, and diskoTest covers it instead.
  vpsModuleFiles = [
    "configuration.nix"
    "modules/caddy.nix"
    "modules/headscale.nix"
    "modules/authentik.nix"
  ];

  vpsConfig = evalHost ([ sopsModule ] ++ map (f: ../headscale-vps + "/${f}") vpsModuleFiles);

  servicesConfig = evalHost [
    sopsModule
    ../nixos/configuration.nix
  ];

  # The services VM again, WITH hardware-configuration.nix. The VM suites
  # substitute tmpfs mounts for it, so nothing else ever evaluates its
  # tmpfiles rules — reverting the /srv/stacks ownership rule would keep every
  # suite green while breaking GitOps delivery in production (see the
  # tmpfiles-ownership lint). Only the parts pure evaluation cannot honour are
  # stubbed, and each stub names its coverage cost:
  servicesFullConfig = evalHost [
    sopsModule
    ../nixos/configuration.nix
    ../nixos/hardware-configuration.nix
    {
      # Coverage cost: the real fileSystems (by-label/by-partlabel devices,
      # the /var/lib/docker bind mount) are replaced wholesale, so lints
      # reading this config must not assert anything about mounts — only the
      # VM suites' tmpfs stand-ins and the real host exercise those.
      fileSystems = lib.mkForce {
        "/" = {
          device = "tmpfs";
          fsType = "tmpfs";
        };
      };
      # hardware-configuration.nix forces grub back on with a real device;
      # evalHost's plain `enable = false` would merely conflict with it, so
      # this one needs mkForce. Same rationale as evalHost: nothing the lints
      # read depends on the bootloader.
      boot.loader.grub.enable = lib.mkForce false;
    }
  ];

  callSuite =
    path: args:
    import path (
      {
        inherit
          pkgs
          lib
          images
          profiles
          sopsModule
          acmeServerModule
          ;
      }
      // args
    );

  lints = import ./lib/lints.nix {
    inherit
      pkgs
      lib
      vpsConfig
      servicesConfig
      servicesFullConfig
      vpsModuleFiles
      images
      ;
  };

  suites = {
    vps = callSuite ./suites/vps.nix { };
    services = callSuite ./suites/services-vm.nix { };
    tailnet = callSuite ./suites/tailnet.nix { };

    # Heavy tier: multi-GB images, minutes not seconds. Run when touching the
    # thing they cover, and in CI — not on every edit.
    authentik = callSuite ./suites/authentik.nix { };
    paperless = callSuite ./suites/paperless.nix { };
    backrest = callSuite ./suites/backrest.nix { };
    rotation = callSuite ./suites/rotation.nix { };
    gitops = callSuite ./suites/gitops.nix { };
    forwardauth = callSuite ./suites/forward-auth.nix { };
    forgejo = callSuite ./suites/forgejo.nix { };
    media = callSuite ./suites/media.nix { };
    # Hand-written, NOT in stackChecks: its restart:"no" oneshot init
    # containers fail mk-stack-suite's generic all-containers-running check.
    immich = callSuite ./suites/immich.nix { };
    # Hand-written for the same reason as immich: kavita-config-init and
    # books-init are restart:"no" oneshots.
    books = callSuite ./suites/books.nix { };
    # Three restart:"no" oneshots, and a Frigate that reports HEALTHY on a
    # broken config (safe mode) — the generic suite would pass on a stack
    # doing nothing at all.
    automation = callSuite ./suites/automation.nix { };
    # One of the three Tracking-range stacks (annex §1). Hand-written: a
    # restart:"no" init oneshot, and three apps whose builtin healthchecks
    # variously lie.
    tracking = callSuite ./suites/tracking.nix { };
    firefly = callSuite ./suites/firefly.nix { };
    dawarich = callSuite ./suites/dawarich.nix { };
    vaultwarden = callSuite ./suites/vaultwarden.nix { };
    notes-sync = callSuite ./suites/notes-sync.nix { };
    util = callSuite ./suites/util.nix { };
    windmill = callSuite ./suites/windmill.nix { };
    restore = callSuite ./suites/restore.nix { };
    tandoor = callSuite ./suites/tandoor.nix { };
    wger = callSuite ./suites/wger.nix { };
  };

  # One fast suite per stack, for iterating on a single stack without booting
  # everything else: nix-build tests -A stackChecks.<name>
  mkStackSuite = import ./lib/mk-stack-suite.nix {
    inherit
      pkgs
      lib
      images
      profiles
      sopsModule
      ;
  };

  # caddy is deliberately absent: it needs the DNS-01 -> tls-internal
  # Caddyfile substitution and a TAILNET_IP, which the generic suite cannot
  # provide. Its routing is covered by the services and tailnet suites.
  stackChecks = lib.genAttrs [
    "ntfy"
    "util"
  ] (name: mkStackSuite { stack = name; });
in
rec {
  inherit
    pkgs
    lints
    suites
    images
    ;

  # Expose the evaluated production configs for ad-hoc inspection:
  #   nix-instantiate --eval tests -A config.vps.services.headscale.settings.port
  config = {
    vps = vpsConfig;
    services = servicesConfig;
  };

  checks = suites // {
    # One derivation that fails if any lint fails, so the fast gate is a single
    # build. Named entries stay individually buildable for a targeted re-run.
    lints = pkgs.runCommand "lints" { } ''
      ${lib.concatMapStringsSep "\n" (d: "echo '--- ${d.name}'; cat ${d} >/dev/null") (
        lib.attrValues lints
      )}
      touch $out
    '';
  };

  inherit stackChecks;

  # Boot-the-image test: the services VM's image module set + cloud-init
  # age-key injection + first-boot sops decryption, asserted via the qemu
  # guest agent. Outside `suites` (a raw qemu runCommand, no driverInteractive).
  proxmoxBoot = import ./suites/proxmox-boot.nix {
    inherit pkgs lib sopsModule;
    nixpkgs = sources.nixpkgs;
  };

  # Disk layout test for headscale-vps/disk-config.nix, via disko's own
  # makeDiskoTest. Separate from `suites` because it is not a runNixOSTest and
  # has no driverInteractive.
  diskoTest = import ./suites/disko.nix {
    inherit pkgs lib;
    diskoSource = sources.disko;
  };

  # Interactive drivers, for poking at a live VM when an assertion fails.
  driver = lib.mapAttrs (_: t: t.driverInteractive) suites;

  # diskoTest is appended explicitly: it lives outside `checks` (not a
  # runNixOSTest, no driverInteractive — see above) but "all" must still build
  # it, or the only coverage disk-config.nix has silently never runs.
  all = pkgs.linkFarmFromDrvs "all-checks" (
    lib.attrValues checks ++ lib.attrValues stackChecks ++ [ diskoTest proxmoxBoot ]
  );
}
