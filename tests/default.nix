# Test harness for BasicBastardSelfhosted. Entry point: ./run.sh; see
# ./README.md for what each suite covers and cannot.
#
# Deliberately NOT a flake: flakes only see git-tracked files, so every edit to
# an in-progress module would need a `git add` before it could be tested, and
# path inputs would need a re-lock. nixpkgs is pinned from the root
# flake.lock instead (lib/sources.nix), so the suites evaluate against exactly
# the nixpkgs the hosts are built with.

{
  system ? builtins.currentSystem,
}:

let
  sources = import ./lib/sources.nix { lockFile = ../flake.lock; };

  pkgs = import sources.nixpkgs { inherit system; };
  inherit (pkgs) lib;

  images = import ./lib/images.nix;

  profiles = import ./lib/profiles.nix {
    inherit lib;
    testKeyFile = ./keys/test-age-key.txt;
  };

  sopsModule = "${sources.sops-nix}/modules/sops";

  # nixpkgs' own Pebble module, so Caddy runs its REAL ACME client through a
  # real HTTP-01 challenge; only the CA differs from production.
  acmeServerModule = "${sources.nixpkgs}/nixos/tests/common/acme/server";

  # Production configs

  # The REAL values — no test overrides — so lints can assert the contracts
  # the VM suites necessarily override away (server_url, the OIDC issuer, the
  # production sops file).
  evalHost =
    modules:
    (import "${sources.nixpkgs}/nixos/lib/eval-config.nix" {
      inherit system;
      modules = modules ++ [
        # Keeps evaluation from demanding a bootloader device or real disks.
        { boot.loader.grub.enable = false; }
      ];
    }).config;

  # The same module set the root flake deploys (headscale-vps/host.nix), so the
  # lints cannot evaluate a config the host does not run.
  vpsConfig = evalHost [
    sopsModule
    ../headscale-vps/host.nix
  ];

  servicesConfig = evalHost [
    sopsModule
    ../nixos/configuration.nix
  ];

  # The services VM WITH hardware-configuration.nix — the only eval that sees
  # its tmpfiles rules, since every VM suite replaces the file with tmpfs
  # stubs. See the tmpfiles-ownership lint.
  servicesFullConfig = evalHost [
    sopsModule
    ../nixos/configuration.nix
    ../nixos/hardware-configuration.nix
    {
      # Coverage cost: the real fileSystems are replaced wholesale, so no lint
      # reading this config may assert anything about mounts.
      fileSystems = lib.mkForce {
        "/" = {
          device = "tmpfs";
          fsType = "tmpfs";
        };
      };
      # hardware-configuration.nix forces grub back on with a real device, so
      # evalHost's plain `enable = false` would merely conflict with it.
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
      images
      ;
    # Keys only; laziness keeps this from forcing any suite derivation.
    suiteNames = builtins.attrNames suites;
  };

  suites = {
    vps = callSuite ./suites/vps.nix { };
    services = callSuite ./suites/services-vm.nix { };
    tailnet = callSuite ./suites/tailnet.nix { };

    # Heavy tier: multi-GB images, minutes not seconds. Run when touching the
    # thing they cover, and in CI — not on every edit. README.md's suite table
    # says what each one proves and what it cannot.
    #
    # A stack has a hand-written suite here rather than a generic stackCheck
    # when mk-stack-suite structurally cannot make its claim — a restart:"no"
    # init one-shot fails its all-containers-running check, a healthcheck that
    # reports HEALTHY on a broken config makes green meaningless, or the
    # contract is a protocol dialogue rather than a port answering.
    authentik = callSuite ./suites/authentik.nix { };
    paperless = callSuite ./suites/paperless.nix { };
    backrest = callSuite ./suites/backrest.nix { };
    rotation = callSuite ./suites/rotation.nix { };
    gitops = callSuite ./suites/gitops.nix { };
    forwardauth = callSuite ./suites/forward-auth.nix { };
    forgejo = callSuite ./suites/forgejo.nix { };
    media = callSuite ./suites/media.nix { };
    immich = callSuite ./suites/immich.nix { };
    books = callSuite ./suites/books.nix { };
    automation = callSuite ./suites/automation.nix { };
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
    mealie = callSuite ./suites/mealie.nix { };
    actual = callSuite ./suites/actual.nix { };
    wealthfolio = callSuite ./suites/wealthfolio.nix { };
    excalidraw = callSuite ./suites/excalidraw.nix { };
    grist = callSuite ./suites/grist.nix { };
    penpot = callSuite ./suites/penpot.nix { };
    gatus = callSuite ./suites/gatus.nix { };
    proton = callSuite ./suites/proton.nix { };
    beszel = callSuite ./suites/beszel.nix { };
    docspace = callSuite ./suites/docspace.nix { };
    # Not a stack suite: the daemon-level journald log driver, and with it the
    # `docker logs` contract every other suite's assertions rest on.
    journald-logging = callSuite ./suites/journald-logging.nix { };
    silverbullet = callSuite ./suites/silverbullet.nix { };
    outline = callSuite ./suites/outline.nix { };
    victorialogs = callSuite ./suites/victorialogs.nix { };
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

  # Stacks whose shape fits the generic harness: no restart:"no" one-shot
  # (finding #39) and no healthcheck that lies. Six of them ALSO carry a
  # hand-written suite above, which covers what a green generic run cannot.
  # caddy is deliberately absent — it needs the DNS-01 -> tls-internal
  # substitution and a TAILNET_IP; services and tailnet cover its routing.
  # grist is absent too: its OIDC discovery is boot-fatal, so it boots only
  # beside the issuer stub its own suite provides.
  stackChecks = lib.genAttrs [
    "ghostfolio"
    "logging"
    "ntfy"
    "proton"
    "owl"
    "util"
    "outline"
    "silverbullet"
    "excalidraw"
  ] (name: mkStackSuite { stack = name; })
  // {
    # Five containers and ~3.3 GB of images (the exporter bundles Chromium,
    # the backend a JVM): the default 3 GB / 8 GB VM holds neither.
    penpot = mkStackSuite {
      stack = "penpot";
      memoryMB = 6144;
      diskMB = 20480;
    };
  };
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

  checks =
    suites
    // (
      let
        # STRUCTURAL lints say the code is internally coherent and must always
        # be green. DEPLOY-READINESS lints go red purely because an operator
        # has not yet supplied a production value — a checklist item, not a
        # broken build — so they stay out of the default gate.
        deployLintNames = [ "sops-declared" ];
        structuralLints = builtins.removeAttrs lints deployLintNames;
        mkAgg =
          name: set:
          pkgs.runCommand name { } ''
            ${lib.concatMapStringsSep "\n" (d: "echo '--- ${d.name}'; cat ${d} >/dev/null") (
              lib.attrValues set
            )}
            touch $out
          '';
      in
      {
        # The always-green gate. `lints.<name>` stays individually buildable.
        lints = mkAgg "lints" structuralLints;
        deploy-check = mkAgg "deploy-check" lints;
      }
    );

  inherit stackChecks;

  # Outside `suites`: a raw qemu runCommand, so no driverInteractive.
  proxmoxBoot = import ./suites/proxmox-boot.nix {
    inherit pkgs lib sopsModule;
    inherit (sources) nixpkgs;
  };

  # disk-config.nix via disko's own makeDiskoTest; likewise not a runNixOSTest.
  diskoTest = import ./suites/disko.nix {
    inherit pkgs lib;
    diskoSource = sources.disko;
  };

  driver = lib.mapAttrs (_: t: t.driverInteractive) suites;

  # diskoTest and proxmoxBoot are appended explicitly: they live outside
  # `checks`, and without them "all" would silently never run the only
  # coverage disk-config.nix and the image recipe have.
  all = pkgs.linkFarmFromDrvs "all-checks" (
    lib.attrValues checks ++ lib.attrValues stackChecks ++ [ diskoTest proxmoxBoot ]
  );
}
