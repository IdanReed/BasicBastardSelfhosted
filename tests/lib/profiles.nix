# Shared test-only overrides.
#
# Design rule for everything in this file: override the *environment*, never
# the behaviour under test. Anything mkForce'd here is something a VM
# physically cannot provide (a Hetzner NIC, a Let's Encrypt challenge, a real
# age key) — not a config choice we found inconvenient. Every override carries
# the reason, because an override that quietly disables the thing a suite
# claims to check is worse than having no suite.
#
# Where an override does cost coverage, the loss is named in a comment and, if
# it can be, recovered by a pure lint in ./lints.nix against the real value.

{ lib, testKeyFile }:

rec {
  # --------------------------------------------------------------------------
  # Boot / hardware
  # --------------------------------------------------------------------------
  # Both hosts declare a bootloader for real hardware (grub on Hetzner's MBR
  # disk, grub on Proxmox's /dev/sda). The test driver boots the kernel
  # directly, and disko's partitioning is meaningless against a qcow the driver
  # created — so neither can apply.
  #
  # Coverage lost: bootloader installation and disk-config.nix. disko ships its
  # own makeDiskoTest for the latter; wiring it up is a separate suite.
  noBootloader = {
    boot.loader.grub.enable = lib.mkForce false;
    boot.loader.systemd-boot.enable = lib.mkForce false;
  };

  # The VPS config asks for DHCP on eth0 because Hetzner provides it. Test
  # nodes get static addresses on vlan interfaces from the driver, and leaving
  # DHCP on makes boot wait for a lease that never arrives.
  # Only eth0 is neutralised. The test driver configures the vlan interfaces
  # (eth1+) itself, so clearing networking.interfaces wholesale would strip the
  # nodes of their addresses and every assertion would fail on a dead network.
  noDhcp = {
    networking.useDHCP = lib.mkForce false;
    networking.interfaces.eth0.useDHCP = lib.mkForce false;
  };

  # --------------------------------------------------------------------------
  # Secrets
  # --------------------------------------------------------------------------
  # Points sops-nix at a fixture encrypted to the committed throwaway key, and
  # plants that key where the real config expects to find it.
  #
  # This deliberately exercises the real sops-nix activation path rather than
  # stubbing secrets in. A secret that fails to decrypt, or lands with the
  # wrong owner or mode, is a genuine deploy failure mode on both hosts, and it
  # is one of the few that a config review does not catch.
  #
  # Coverage lost: that the *production* secrets.sops.yaml decrypts, which is
  # impossible without the production key. lints.nix compares key sets across
  # the example, the fixture, and the real encrypted file (sops-yaml keys are
  # plaintext) instead, so a secret added to one without the others still fails.
  #
  # The format is NOT overridden: the host config's own defaultSopsFormat is
  # part of what is under test — the dotenv format silently broke per-key
  # extraction once already (see the sops-dotenv-extraction lint).
  sopsFixture =
    fixture:
    { config, ... }:
    {
      sops.defaultSopsFile = lib.mkForce fixture;

      # Both hosts hardcode this path, and it is populated out of band on real
      # hardware (cloud-init on Proxmox, --extra-files on Hetzner). Plant it
      # before sops-nix runs rather than overriding sops.age.keyFile, so the
      # path the real config names is the path actually used.
      system.activationScripts.plantTestAgeKey = {
        deps = [ ];
        text = ''
          install -Dm600 ${testKeyFile} /var/lib/sops-nix/sops_age_key.txt
        '';
      };
      system.activationScripts.setupSecrets.deps = [ "plantTestAgeKey" ];
    };

  # --------------------------------------------------------------------------
  # Container images
  # --------------------------------------------------------------------------
  # Loads pinned images into the guest's docker before anything that needs
  # them. The suites run with no network — that is what makes them
  # reproducible — so every image must already be in the store.
  #
  # This is ordered before the units under test rather than done from the test
  # script, because bootstrap-arcane and authentik.service are wantedBy
  # multi-user.target and therefore run during boot, before the script gets
  # control.
  loadImages =
    { pkgs, images, beforeUnits }:
    let
      tarballs = map (
        img:
        pkgs.dockerTools.pullImage {
          inherit (img)
            imageName
            imageDigest
            hash
            finalImageName
            finalImageTag
            ;
        }
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

  # --------------------------------------------------------------------------
  # Pebble issuing-root trust
  # --------------------------------------------------------------------------
  # Pebble (the ACME server standing in for Let's Encrypt) generates a FRESH
  # issuing root on every run — deliberately, upstream's way of stopping people
  # from ever trusting a test CA permanently. security.pki.certificateFiles is
  # baked at eval time, so it can only carry the static CA for Pebble's own
  # management endpoint, never the per-run root that signs the certificates
  # Caddy obtains.
  #
  # So the root is fetched at runtime from Pebble's authenticated management
  # API (https://<ca>:15000/roots/0, served under the static CA) and written to
  # /var/lib/test-ca/bundle.pem together with that static CA. Consumers:
  #
  #   - test scripts:            curl --cacert /var/lib/test-ca/bundle.pem
  #   - tailscaled:              SSL_CERT_FILE (Go honours it) — otherwise no
  #                              node can `tailscale up --login-server` against
  #                              a Caddy serving a Pebble certificate
  #   - tailscale-autoconnect:   its readiness poll curls the public HTTPS URL
  #   - headscale:               OIDC discovery against auth.idanreed.com
  #
  # Env injection into those units is a test-only override; the units
  # themselves run unmodified. `before`/`requiredBy` on units a node does not
  # have are ignored by systemd, so one profile serves every node shape.
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

  # --------------------------------------------------------------------------
  # SSH access
  # --------------------------------------------------------------------------
  # Authorises the committed throwaway keypair (tests/keys/test-ssh-key) for
  # the idan user, standing in for the real key the production configs still
  # carry a TODO for. What this makes testable, from another node:
  #   - key login works at all (the TODO placeholder means it currently would
  #     not — no key is authorised on either host)
  #   - PasswordAuthentication no actually refuses passwords
  #   - PermitRootLogin no actually refuses root
  #   - wheelNeedsPassword = false gives passwordless sudo over SSH
  testSshAccess = {
    users.users.idan.openssh.authorizedKeys.keys = [
      (lib.removeSuffix "\n" (builtins.readFile ../keys/test-ssh-key.pub))
    ];
  };

  # --------------------------------------------------------------------------
  # tailscale-autoconnect
  # --------------------------------------------------------------------------
  # Takes the unit out of the boot path without changing a line of it.
  #
  # It is Type=oneshot, wantedBy=multi-user.target, and on the VPS it polls
  # https://headscale.idanreed.com/health up to 30 times at 10s intervals before
  # running `tailscale up`. With the fixture's placeholder auth key it then
  # fails, and Restart=on-failure retries forever — so multi-user.target is
  # never reached and every wait_for_unit in the suite hangs.
  #
  # The suites create a real preauth key, write it over the decrypted secret,
  # and start this unit explicitly. The unit that runs is the real one,
  # --login-server and all; only its trigger moves.
  manualTailscaleAutoconnect = {
    systemd.services.tailscale-autoconnect.wantedBy = lib.mkForce [ ];
  };

  # Docker 28.x is marked insecure in nixos-25.11 and makes the whole
  # configuration refuse to evaluate. Both host configs already pin docker_29;
  # this only matters for extra test nodes that enable docker themselves.
  dockerPin =
    { pkgs, ... }:
    {
      virtualisation.docker.package = lib.mkDefault pkgs.docker_29;
    };

  # --------------------------------------------------------------------------
  # Sizing
  # --------------------------------------------------------------------------
  # Container hosts need considerably more than the driver's 1024MB default;
  # Authentik alone will not finish its migrations below ~3GB.
  sized =
    { memoryMB, diskMB }:
    {
      virtualisation.memorySize = memoryMB;
      virtualisation.diskSize = diskMB;
      virtualisation.cores = 2;
    };
}
