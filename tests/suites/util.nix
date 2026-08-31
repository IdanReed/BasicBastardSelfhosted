# Util suite: bentopdf, mazanoke, glance and it-tools.
#
# All four are static-or-nearly-static browser tools where "it serves" is close
# to the whole contract, so this suite is deliberately short. Its value is in
# the two things that are NOT obvious.
#
# Genuinely under test:
#   - **Glance serves its shell and healthz OFFLINE, and its content endpoint
#     is never probed.** Widget fetches happen inside the page-content handler
#     and `wg.Wait()` on every widget goroutine, so with no egress that endpoint
#     stalls the whole page rather than degrading one tile. glance.yml ships no
#     egress-dependent widget for that reason; this suite records why the
#     obvious probe is absent.
#   - **The stack needs no secrets at all**, asserted rather than assumed. It
#     HAD a `.sops.env` while ExcaliDash was in it, and dropping the last
#     stateful service is exactly the moment a leftover `env_file` would start
#     failing Arcane's staged sync for bentopdf and mazanoke too (finding #11).
#   - every published port is loopback-only, with a positive control.
#
# 🚨 ExcaliDash was here and is DEFERRED — see stacks/util/compose.yaml. Its
# entrypoint runs `npx prisma generate` unconditionally at container start and
# its schema hardcodes a binaryTarget for the OTHER architecture, so it always
# reaches binaries.prisma.sh and dies without egress. That is a crash loop on a
# tailnet-only host, not a slow start. Found by this suite's first run.
#
# Documented gaps:
#   - **Forward auth** for all four — that hop needs the VPS outpost and is
#     tests/suites/forward-auth.nix's job.
#   - **Glance's hot-reload failure mode**: a bad reload leaves the OLD config
#     running with healthz still 200, and nothing can detect it from outside.

{
  pkgs,
  lib,
  images,
  profiles,
  sopsModule,
  ...
}:

let
  stackImages = [
    images."ghcr_io_alam00000_bentopdf_1_16_1"
    images."ghcr_io_civilblur_mazanoke_v1_1_5"
    images."glanceapp_glance_v0_8_5"
    images."corentinth_it-tools_2024_10_22-7ca5933"
  ];

  seedSrv = pkgs.runCommand "srv-seed-util" { } ''
    mkdir -p $out/stacks/util
    cp -r ${../../stacks/util}/. $out/stacks/util/
    chmod -R u+w $out/stacks/util
    rm -f $out/stacks/util/.env
    rm -f $out/stacks/util/.sops.env.example
  '';
in
pkgs.testers.runNixOSTest {
  name = "util";

  globalTimeout = 3600;

  nodes = {
    services =
      { config, pkgs, ... }:
      {
        imports = [
          sopsModule
          ../../nixos/configuration.nix

          profiles.noBootloader
          profiles.noDhcp
          profiles.manualTailscaleAutoconnect
          (profiles.sopsFixture ../fixtures/services-vm.sops.yaml)
          (profiles.sized {
            memoryMB = 3072;
            diskMB = 12288;
          })
          (profiles.loadImages {
            inherit pkgs;
            images = stackImages;
            beforeUnits = [ "multi-user.target" ];
          })
        ];

        systemd.services.bootstrap-arcane.wantedBy = lib.mkForce [ ];
        virtualisation.cores = lib.mkForce 2;

        virtualisation.emptyDiskImages = [ 4096 ];
        virtualisation.fileSystems = {
          "/srv" = {
            device = "tmpfs";
            fsType = "tmpfs";
            options = [ "mode=0755" ];
          };
          "/mnt" = {
            device = "/dev/vdb";
            fsType = "ext4";
            autoFormat = true;
          };
        };

        systemd.tmpfiles.rules = [
          "d /srv/stacks 0755 1000 1000 -"
          "d /var/lib/sops-nix 0700 root root -"
          "d /mnt/fast 0755 root root -"
          "d /mnt/slow 0755 root root -"
        ];

        systemd.services.seed-srv = {
          description = "Seed /srv from the repo (test only)";
          after = [ "srv.mount" ];
          requires = [ "srv.mount" ];
          before = [ "decrypt-sops-envs.service" ];
          requiredBy = [ "decrypt-sops-envs.service" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            mkdir -p /srv/stacks
            cp -r --no-preserve=mode ${seedSrv}/stacks/. /srv/stacks/
            chown -R 1000:1000 /srv/stacks
          '';
        };

        environment.systemPackages = with pkgs; [ docker-compose jq ];
      };

    outsider = { };
  };

  testScript = ''
    UTIL = "docker compose -f /srv/stacks/util/compose.yaml -p util"

    PORTS = {
        "bentopdf": 10401,
        "glance": 10402,
        "mazanoke": 10403,
        "it-tools": 10407,
    }

    def diag(label):
        print("=== diagnostics: " + label + " ===")
        for cmd in [
            "docker ps -a",
            "docker logs glance 2>&1 | tail -30",
            "docker logs it-tools 2>&1 | tail -20",
            "df -h /var/lib/docker /mnt; free -m",
        ]:
            print("--- " + cmd)
            print(services_vm.execute(cmd)[1])

    def status(port, path="/"):
        return int(services_vm.succeed(
            "curl -s -o /dev/null -w '%{http_code}' --max-redirs 0 "
            f"--max-time 30 http://127.0.0.1:{port}{path}"
        ).strip())

    start_all()

    with subtest("the stack needs no secrets at all"):
        services_vm.wait_for_unit("multi-user.target")
        services_vm.wait_for_unit("docker-network-homelab.service")
        # Asserted rather than assumed: this stack HAD a .sops.env while
        # ExcaliDash was in it, and dropping the last stateful service is
        # exactly the moment a leftover env_file would start failing Arcane's
        # staged sync for bentopdf and mazanoke too.
        services_vm.fail("test -e /srv/stacks/util/.sops.env")
        services_vm.fail("grep -q env_file /srv/stacks/util/compose.yaml")

    services_vm.wait_for_unit("load-test-images.service")

    with subtest("compose up brings every container healthy"):
        try:
            services_vm.succeed(f"{UTIL} up -d --wait --wait-timeout 900")
        except Exception:
            diag("compose up failed")
            raise

    with subtest("Glance serves offline, and its content endpoint is left alone"):
        assert status(PORTS["glance"], "/api/healthz") == 200
        assert status(PORTS["glance"], "/") in (200, 302)
        # Deliberately NOT probing /api/pages/*/content/: widget fetches happen
        # inside that handler and wg.Wait() on every widget goroutine, so with
        # no egress it stalls until each client times out. glance.yml ships no
        # egress-dependent widget for exactly that reason; this subtest exists
        # to record why the obvious probe is absent.

    with subtest("the three static tools serve"):
        for name in ["bentopdf", "mazanoke", "it-tools"]:
            code = status(PORTS[name])
            assert code in (200, 302), f"{name} returned {code}"

    with subtest("every published port is loopback-only, with a positive control"):
        ip = services_vm.succeed(
            "ip -4 -o addr show eth1 | awk '{print $4}' | cut -d/ -f1"
        ).strip()
        outsider.wait_for_unit("network.target")
        for name, port in sorted(PORTS.items()):
            outsider.fail(
                f"curl -s --max-time 10 http://{ip}:{port}/ >/dev/null",
            )
        outsider.succeed(f"ping -c1 -W5 {ip} >/dev/null")

    with subtest("state survives a reboot"):
        # shutdown()+start(), not reboot(): qemu runs with -no-reboot.
        services_vm.shutdown()
        services_vm.start()
        services_vm.wait_for_unit("multi-user.target")
        # NOT ".env" — this stack has no secrets since ExcaliDash was
        # deferred, so decrypt-sops-envs writes nothing here. Wait on the
        # thing that actually appears: the seeded compose file.
        services_vm.wait_until_succeeds(
            "test -s /srv/stacks/util/compose.yaml", timeout=180
        )
        services_vm.wait_for_unit("load-test-images.service")
        services_vm.succeed(f"{UTIL} up -d --wait --wait-timeout 900")
  '';
}
