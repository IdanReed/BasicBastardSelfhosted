# Gatus suite — small, because Gatus is a config file with a binary attached.
# Its value is in three assertions the generic machinery structurally cannot
# make.
#
# Genuinely under test:
#   - 🚨 **The loopback bind, from another machine.** Gatus is
#     `network_mode: host`, so it has no `ports:` entry — which makes it
#     invisible to `loopback-binding` and to mk-stack-suite's port probe. Per
#     the `host-network-declared` lint's own error text, such a service
#     "passes them with an empty set rather than failing". The only real proof
#     is an outsider failing to reach 10450, exactly as the vps suite does for
#     headscale.
#   - **The config actually loaded**, asserted by counting endpoints rather
#     than by the process being up. A config that syncs empty is a HARD startup
#     failure (`ErrNoEndpointOrSuiteInConfig`) rather than a silent no-op, and
#     the suite proves that too — with an empty config directory in a throwaway
#     container.
#   - **No healthcheck exists, deliberately.** The image is `FROM scratch`:
#     one binary, one embedded config, the CA bundle. No shell, no curl, no
#     wget, no `gatus healthcheck` subcommand. Declaring a probe here would
#     mean declaring one that lies. The suite pins the absence so nobody
#     "fixes" it, and probes `/health` from the host instead.
#
# Documented gaps:
#   - **Every probe Gatus itself makes.** In an offline VM with none of the
#     monitored services running, every endpoint is DOWN — which is correct
#     behaviour and proves nothing. What is asserted is that the endpoints were
#     PARSED and are being evaluated, not their results.
#   - **Alerting to ntfy.** The provider is configured; nothing here makes it
#     fire. The unhealthy-container timer's own subtests in the util suite
#     cover the other alerting path.
#   - **Forward auth.** Needs the VPS outpost.

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
    images."ghcr_io_twin_gatus_v5_36_0"
  ];

  seedSrv = pkgs.runCommand "srv-seed-gatus" { } ''
    mkdir -p $out/stacks/gatus
    cp -r ${../../stacks/gatus}/. $out/stacks/gatus/
    chmod -R u+w $out/stacks/gatus
    rm -f $out/stacks/gatus/.env
  '';
in
pkgs.testers.runNixOSTest {
  name = "gatus";

  globalTimeout = 2400;

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
            memoryMB = 2048;
            diskMB = 8192;
          })
          (profiles.loadImages {
            inherit pkgs;
            images = stackImages;
            beforeUnits = [ "multi-user.target" ];
          })
        ];

        systemd.services.bootstrap-komodo.wantedBy = lib.mkForce [ ];
        # The new stack-git-sync timer would fail its clone every tick with no Forgejo here.
        systemd.timers.stack-git-sync.wantedBy = lib.mkForce [ ];
        virtualisation.cores = lib.mkForce 2;

        virtualisation.fileSystems."/srv" = {
          device = "tmpfs";
          fsType = "tmpfs";
          options = [ "mode=0755" ];
        };

        systemd.tmpfiles.rules = [
          "d /srv/stacks 0755 1000 1000 -"
          "d /var/lib/sops-nix 0700 root root -"
          "d /mnt/fast 0755 root root -"
          "d /mnt/slow 0755 root root -"
          "d /mnt/fast/gatus 0755 root root -"
        ];

        systemd.services.seed-srv = {
          description = "Seed /srv from the repo (test only)";
          after = [ "srv.mount" ];
          requires = [ "srv.mount" ];
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
    import json

    GATUS = "docker compose -f /srv/stacks/gatus/compose.yaml -p gatus"
    BASE = "http://127.0.0.1:10450"

    start_all()

    services_vm.wait_for_unit("multi-user.target")
    services_vm.wait_for_unit("docker-network-homelab.service")
    services_vm.wait_for_unit("load-test-images.service")

    with subtest("gatus starts and answers /health"):
        # No `--wait`: the container has no healthcheck and cannot have one, so
        # naming it in a --wait list is a hard error (finding #42) and waiting
        # on the project would only wait for `running`. /health is the probe.
        services_vm.succeed(f"{GATUS} up -d")
        services_vm.wait_until_succeeds(
            f"curl -fsS -o /dev/null --max-time 10 {BASE}/health", timeout=120
        )

    with subtest("no healthcheck is configured, and that is deliberate"):
        # FROM scratch: one binary, one embedded config, the CA bundle. There
        # is no shell, no curl, no wget and no `gatus healthcheck` subcommand,
        # so any HEALTHCHECK here would have to be a lie. Pinned so nobody
        # "adds the missing healthcheck" later.
        out = services_vm.succeed(
            "docker inspect --format '{{json .Config.Healthcheck}}' gatus"
        ).strip()
        assert out in ("null", "{}"), f"gatus grew a healthcheck: {out}"

    with subtest("the config loaded — endpoints are parsed and evaluated"):
        # Counting endpoints rather than trusting that the process is up. Their
        # RESULTS are meaningless here (nothing they monitor is running in this
        # VM), but their existence proves the config parsed.
        # RETRIED. Each endpoint has its own ticker (1m for service probes,
        # 2m for path probes) and appears in this listing once it has been
        # evaluated at least once — so sampling immediately after /health
        # answers would read a nearly-empty list and assert nothing.
        services_vm.wait_until_succeeds(
            f"curl -fsS --max-time 30 '{BASE}/api/v1/endpoints/statuses' "
            "| jq -e 'length >= 40' >/dev/null",
            timeout=300,
        )
        raw = services_vm.succeed(
            f"curl -fsS --max-time 30 '{BASE}/api/v1/endpoints/statuses'"
        )
        statuses = json.loads(raw)
        assert len(statuses) >= 40, (
            f"only {len(statuses)} endpoints parsed; the config is truncated"
        )
        names = {e.get("name", "") for e in statuses}
        # Both probe kinds must be present. If only one shape survived, the
        # generator that builds this config from the Caddyfile has regressed
        # and half the fleet is being monitored in exactly one of the two ways
        # that are each individually blind.
        assert any("(service)" in n for n in names), sorted(names)[:5]
        assert any("(path:" in n for n in names), sorted(names)[:5]

    with subtest("🚨 an EMPTY config directory is a hard startup failure"):
        # ErrNoEndpointOrSuiteInConfig. This is the right behaviour — a config
        # that syncs empty must not come up monitoring nothing and reporting
        # green — and it is worth pinning, because "starts with no endpoints"
        # is exactly the silent-success shape this whole campaign keeps finding.
        services_vm.succeed("mkdir -p /tmp/emptycfg && : > /tmp/emptycfg/config.yaml")
        services_vm.fail(
            "docker run --rm --name bkg-gatus-empty "
            "-v /tmp/emptycfg/config.yaml:/config/config.yaml:ro "
            "ghcr.io/twin/gatus:v5.36.0"
        )

    with subtest("🚨 10450 is unreachable from another machine"):
        # THE assertion this suite exists for. Gatus is network_mode: host and
        # has no `ports:` entry, so loopback-binding and mk-stack-suite's probe
        # both see an empty set and pass — per host-network-declared's own
        # error text. Only an outsider can prove the bind.
        ip = services_vm.succeed(
            "ip -4 -o addr show eth1 | awk '{print $4}' | cut -d/ -f1"
        ).strip()
        outsider.wait_for_unit("network.target")
        outsider.fail(f"curl -s --max-time 10 http://{ip}:10450/health >/dev/null")
        # Positive control: the outsider can reach the VM at all.
        outsider.succeed(f"ping -c1 -W5 {ip} >/dev/null")

    with subtest("history survives a reboot"):
        # shutdown()+start(), not reboot(): qemu runs with -no-reboot.
        services_vm.succeed("test -f /mnt/fast/gatus/gatus.db")
        services_vm.shutdown()
        services_vm.start()
        services_vm.wait_for_unit("multi-user.target")
        services_vm.wait_for_unit("load-test-images.service")
        services_vm.succeed(f"{GATUS} up -d")
        services_vm.wait_until_succeeds(
            f"curl -fsS -o /dev/null --max-time 10 {BASE}/health", timeout=120
        )
        services_vm.succeed("test -f /mnt/fast/gatus/gatus.db")
  '';
}
