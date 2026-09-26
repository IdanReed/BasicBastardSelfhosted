# Shared test-only overrides.
#
# Design rule: override the ENVIRONMENT, never the behaviour under test.
# Everything mkForce'd here is something a VM physically cannot provide. Where
# an override costs coverage the loss is named, and ./lints.nix recovers it
# against the real value where it can.

{ lib, testKeyFile }:

{
  # Boot / hardware

  # Both hosts declare a bootloader for real hardware; the driver boots the
  # kernel directly. Coverage lost: bootloader installation and
  # disk-config.nix — the disko suite covers the latter.
  noBootloader = {
    boot.loader.grub.enable = lib.mkForce false;
    boot.loader.systemd-boot.enable = lib.mkForce false;
  };

  # eth0 ONLY: the driver configures eth1+ itself, so clearing
  # networking.interfaces wholesale would leave every node with no address.
  # The gateway goes too — the services VM's `defaultGateway = 10.0.0.1` has
  # no interface to hang off on a test vlan, and network-setup.service dies
  # lazily, mid-test, breaking only the no-failed-units assertion.
  noDhcp = {
    networking.useDHCP = lib.mkForce false;
    networking.interfaces.eth0.useDHCP = lib.mkForce false;
    networking.defaultGateway = lib.mkForce null;
  };

  # Secrets

  # A fixture encrypted to the committed throwaway key, exercising the REAL
  # sops-nix activation path (wrong owner or mode is a genuine deploy failure
  # config review does not catch). defaultSopsFormat is deliberately NOT
  # overridden — see the sops-dotenv-extraction lint.
  #
  # Coverage lost: that the production secrets.sops.yaml decrypts; the
  # sops-declared lint compares key sets instead.
  sopsFixture =
    fixture:
    _: {
      sops.defaultSopsFile = lib.mkForce fixture;

      # Both hosts hardcode this path and populate it out of band (cloud-init
      # on Proxmox, --extra-files on Hetzner). Planting the key beats
      # overriding sops.age.keyFile: the path the real config names is used.
      system.activationScripts.plantTestAgeKey = {
        deps = [ ];
        text = ''
          install -Dm600 ${testKeyFile} /var/lib/sops-nix/sops_age_key.txt
        '';
      };
      system.activationScripts.setupSecrets.deps = [ "plantTestAgeKey" ];
    };

  # Container images

  # The suites have no network, so every image must come from the store. Done
  # as a unit ordered BEFORE the units under test, not from the test script:
  # bootstrap-komodo and authentik.service are wantedBy multi-user.target and
  # run during boot, before the script gets control.
  loadImages =
    { pkgs, images, beforeUnits }:
    let
      tarballs = map (
        img:
        # unsafeDiscardReferences: an image whose layers happen to contain a
        # /nix/store-shaped string (onlyoffice/docspace) is otherwise refused
        # as a fixed-output derivation "not allowed to refer to other store
        # paths". The output is content-addressed by `hash` either way.
        (pkgs.dockerTools.pullImage {
          inherit (img)
            imageName
            imageDigest
            hash
            finalImageName
            finalImageTag
            ;
        }).overrideAttrs
          (_: {
            __structuredAttrs = true;
            unsafeDiscardReferences.out = true;
          })
      ) images;
    in
    { config, ... }:
    {
      systemd.services.load-test-images = {
        description = "Load pinned OCI images into docker (test only)";
        after = [ "docker.service" ];
        requires = [ "docker.service" ];
        wantedBy = [ "multi-user.target" ];
        before = beforeUnits;
        requiredBy = beforeUnits;

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };

        script = lib.concatMapStringsSep "\n" (t: ''
          docker load -i ${t}
        '') tarballs;

        # The host's own docker (pinned to 29.x — pkgs.docker is 28.x and
        # marked insecure), not a second copy.
        path = [ config.virtualisation.docker.package ];
      };
    };

  # Pebble issuing-root trust

  # Pebble mints a FRESH issuing root every run, and
  # security.pki.certificateFiles is baked at eval time — so the per-run root
  # has to be fetched at runtime from Pebble's management API and bundled with
  # the static CA for the units that dial Caddy over HTTPS (tailscaled,
  # tailscale-autoconnect, headscale's OIDC discovery) and for test scripts.
  # Only the environment is injected; the units run unmodified.
  pebbleTrust =
    { caDomain, caCert }:
    { pkgs, lib, ... }:
    let
      bundle = "/var/lib/test-ca/bundle.pem";
      units = [
        "tailscaled.service"
        "tailscale-autoconnect.service"
        "headscale.service"
      ];
    in
    {
      systemd.services =
        {
          fetch-pebble-root = {
            description = "Fetch Pebble's per-run issuing root (test only)";
            wantedBy = [ "multi-user.target" ];
            before = units;
            requiredBy = units;
            after = [ "network-online.target" ];
            wants = [ "network-online.target" ];
            path = [
              pkgs.curl
              pkgs.coreutils
            ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            script = ''
              mkdir -p /var/lib/test-ca
              # All nodes boot simultaneously; Pebble needs a few seconds.
              for i in $(seq 1 60); do
                if curl -sf --cacert ${caCert} \
                     https://${caDomain}:15000/roots/0 \
                     -o /var/lib/test-ca/pebble-root.pem; then
                  break
                fi
                sleep 2
              done
              test -s /var/lib/test-ca/pebble-root.pem
              cat ${caCert} /var/lib/test-ca/pebble-root.pem > ${bundle}
            '';
          };
        }
        // lib.genAttrs (map (u: lib.removeSuffix ".service" u) units) (_: {
          environment.SSL_CERT_FILE = bundle;
        });
    };

  # SSH access

  # The committed throwaway keypair, merged ALONGSIDE the production
  # ssh-pubkeys.nix entries (list options concatenate) — their private halves
  # are sops-encrypted where the harness cannot reach them. This is what makes
  # the sshd negatives testable from another node.
  testSshAccess = {
    users.users.idan.openssh.authorizedKeys.keys = [
      (lib.removeSuffix "\n" (builtins.readFile ../keys/test-ssh-key.pub))
    ];
  };

  # tailscale-autoconnect

  # Takes the unit out of the boot path without changing a line of it: with
  # the fixture's placeholder auth key it fails, Restart=on-failure retries
  # forever, multi-user.target is never reached and every wait_for_unit hangs.
  # The suites mint a real preauth key and start it explicitly, so the unit
  # that runs is the real one — only its trigger moves.
  manualTailscaleAutoconnect = {
    systemd.services.tailscale-autoconnect.wantedBy = lib.mkForce [ ];
    systemd.timers.tailscale-autoconnect.wantedBy = lib.mkForce [ ];
  };

  # Sizing

  # Container hosts need far more than the driver's 1024MB default; Authentik
  # alone will not finish its migrations below ~3GB.
  sized =
    { memoryMB, diskMB }:
    {
      virtualisation.memorySize = memoryMB;
      virtualisation.diskSize = diskMB;
      virtualisation.cores = 2;
    };
}
