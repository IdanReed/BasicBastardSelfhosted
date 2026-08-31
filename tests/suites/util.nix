# Util suite: bentopdf, mazanoke, glance, it-tools and ExcaliDash's two
# containers.
#
# Four of the six are static SPAs where "it serves" is the whole contract, so
# this suite is deliberately short — but ExcaliDash brings two traps that
# nothing generic would catch, and both are the kind that leave a green
# container.
#
# Genuinely under test:
#   - 🚨 **ExcaliDash reaches HEALTHY at all.** ENFORCE_HTTPS_REDIRECT defaults
#     TRUE and its middleware arms whenever NODE_ENV=production and a
#     FRONTEND_URL origin is https — exactly this configuration. The probe then
#     dials http://127.0.0.1:8000/health with no X-Forwarded-Proto, the policy
#     misses the loopback host, falls back to the canonical https host and
#     returns a 302. `statusCode === 200` is false, so the container is
#     permanently unhealthy and `up --wait` never returns. TRUST_PROXY does not
#     save it. Reaching healthy IS the assertion.
#   - 🚨 **The backend boots with an EMPTY OIDC client secret.** That is the
#     non-obvious half of shipping `oidc_enforced` before the secret exists:
#     config.ts throws at startup when the issuer, client id or redirect URI is
#     empty, but the SECRET is deliberately not in that required set. If a
#     future version adds it, this stack crash-loops on deploy — so pin it.
#   - **The backend is not published.** A published backend port would be a
#     second, unauthenticated door to the same API.
#   - dev.db exists where backup-prepare.sh looks — sqlite_backup returns 0 for
#     a missing source, so a wrong path backs up nothing forever.
#   - Glance serves its shell and healthz OFFLINE. Its content endpoint is
#     never probed: widget fetches happen inside that handler and wg.Wait() on
#     every widget goroutine, so with no egress it stalls the whole page rather
#     than degrading one tile.
#   - every published port is loopback-only, with a positive control.
#
# Documented gaps:
#   - **Any ExcaliDash login.** oidc_enforced with no client secret means there
#     is no way in, by design. The suite proves it is closed and boots, not
#     that anyone can use it.
#   - **Forward auth** for glance/it-tools/bentopdf — that hop needs the VPS
#     outpost and is tests/suites/forward-auth.nix's job.
#   - **Glance's hot-reload failure mode**: a bad reload leaves the old config
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
    images."zimengxiong_excalidash-backend_0_6_0"
    images."zimengxiong_excalidash-frontend_0_6_0"
  ];

  seedSrv = pkgs.runCommand "srv-seed-util" { } ''
    mkdir -p $out/stacks/util
    cp -r ${../../stacks/util}/. $out/stacks/util/
    chmod -R u+w $out/stacks/util
    rm -f $out/stacks/util/.env
    rm -f $out/stacks/util/.sops.env.example
    cp ${../fixtures/util.sops.env} $out/stacks/util/.sops.env
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
          # 1001:1001, matching production — the backend chowns this to uid
          # 1001 on every start, so any other owner is silently overwritten.
          "d /mnt/fast/excalidash 0755 1001 1001 -"
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
        "excalidash-frontend": 10406,
        "it-tools": 10407,
    }

    def diag(label):
        print("=== diagnostics: " + label + " ===")
        for cmd in [
            "docker ps -a",
            "docker logs excalidash_backend 2>&1 | tail -60",
            "docker logs excalidash_frontend 2>&1 | tail -30",
            "docker logs glance 2>&1 | tail -30",
            "ls -la /mnt/fast/excalidash 2>&1",
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

    with subtest("decrypt-sops-envs produced a 0600 .env owned by arcane's uid"):
        services_vm.wait_for_unit("multi-user.target")
        services_vm.wait_for_unit("docker-network-homelab.service")
        services_vm.wait_until_succeeds("test -s /srv/stacks/util/.env", timeout=120)
        stat = services_vm.succeed("stat -c '%a %u:%g' /srv/stacks/util/.env").strip()
        assert stat == "600 1000:1000", f".env is {stat}"
        for k in ["EXCALIDASH_JWT_SECRET", "EXCALIDASH_CSRF_SECRET"]:
            services_vm.succeed(f"grep -q '^{k}=.' /srv/stacks/util/.env")
        # Present and EMPTY, and the next subtest is what makes that safe.
        services_vm.succeed(
            "grep -qx 'EXCALIDASH_OIDC_CLIENT_SECRET=' /srv/stacks/util/.env"
        )

    services_vm.wait_for_unit("load-test-images.service")

    with subtest("compose up brings every container healthy"):
        # This single line carries the ENFORCE_HTTPS_REDIRECT assertion: with
        # the flag left at its default the backend's own probe 302s forever,
        # --wait never returns, and the frontend's service_healthy dependency
        # never releases.
        try:
            services_vm.succeed(f"{UTIL} up -d --wait --wait-timeout 900")
        except Exception:
            diag("compose up failed")
            raise

    with subtest("the ExcaliDash backend booted with an EMPTY OIDC secret"):
        # The non-obvious half of shipping oidc_enforced before the secret
        # exists. config.ts throws at STARTUP when the issuer, client id or
        # redirect URI is empty; the client secret is deliberately not in that
        # required set, because a public client is allowed. If a future version
        # adds it, this stack crash-loops on deploy rather than at login.
        env = services_vm.succeed(
            "docker inspect --format "
            "'{{range .Config.Env}}{{println .}}{{end}}' excalidash_backend"
        )
        assert "EXCALIDASH_OIDC_CLIENT_SECRET=" in env
        assert "AUTH_MODE=oidc_enforced" in env, env
        assert "ENFORCE_HTTPS_REDIRECT=false" in env, env
        health = services_vm.succeed(
            "docker inspect --format '{{.State.Health.Status}}' excalidash_backend"
        ).strip()
        assert health == "healthy", f"backend health is {health}"

    with subtest("the ExcaliDash backend is NOT published"):
        # A published backend port would be a second, unauthenticated door to
        # the same API — and overview-sync would demand an inventory row for it.
        out = services_vm.succeed(
            "docker inspect --format '{{json .NetworkSettings.Ports}}' "
            "excalidash_backend"
        ).strip()
        assert '"HostPort"' not in out, f"backend publishes a port: {out}"

    with subtest("ExcaliDash's SQLite file is where backup-prepare.sh looks"):
        # sqlite_backup returns 0 for a MISSING source, so without this the
        # only line covering this stack could be a permanent silent no-op.
        services_vm.succeed("test -f /mnt/fast/excalidash/dev.db")
        owner = services_vm.succeed("stat -c '%u:%g' /mnt/fast/excalidash").strip()
        assert owner == "1001:1001", (
            f"/mnt/fast/excalidash is {owner}; the backend chowns it to "
            "1001:1001 on every start, so anything else means the container "
            "did not run its entrypoint as root"
        )

    with subtest("Glance serves offline, and its content endpoint is left alone"):
        assert status(PORTS["glance"], "/api/healthz") == 200
        assert status(PORTS["glance"], "/") in (200, 302)
        # Deliberately NOT probing /api/pages/*/content/: widget fetches happen
        # inside that handler and wg.Wait() on every widget goroutine, so with
        # no egress it stalls until each client times out. glance.yml ships no
        # egress-dependent widget for exactly that reason; this subtest exists
        # to record why the obvious probe is absent.

    with subtest("the four static tools serve"):
        for name in ["bentopdf", "mazanoke", "it-tools", "excalidash-frontend"]:
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
        services_vm.wait_until_succeeds("test -s /srv/stacks/util/.env", timeout=180)
        services_vm.wait_for_unit("load-test-images.service")
        services_vm.succeed(f"{UTIL} up -d --wait --wait-timeout 900")
        services_vm.succeed("test -f /mnt/fast/excalidash/dev.db")
  '';
}
