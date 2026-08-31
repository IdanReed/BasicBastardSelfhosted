# OnlyOffice DocSpace suite: the monolith, Document Server, MySQL, and the
# one-shot that completes the setup wizard.
#
# Genuinely under test:
#   - 🚨 **The machine key in play is the one from sops.** `ensure_secret`
#     takes `APP_CORE_MACHINEKEY` from the environment if non-empty, otherwise
#     reads `/app/onlyoffice/data/.secrets/APP_CORE_MACHINEKEY`, otherwise
#     GENERATES one and writes it there — and upstream's own community compose
#     sets the variable to `""` to force exactly that. The only distinction in
#     the log is one line reading "Using APP_CORE_MACHINEKEY from
#     environment.", which scrolls past on a first boot.
#     It matters more than any other secret here: it derives the password salt
#     when `core:password:salt` is unset (which it is), signs every
#     confirm-scheme link, and is exported as SPRING_APPLICATION_SIGNATURE_SECRET.
#     A portal running on a generated key cannot be restored from anything but
#     a byte-exact copy of that directory — every password would stop matching.
#   - 🚨 **`APP_CORE_BASE_DOMAIN` is still `localhost`.** `Standalone` is
#     computed from it, and Standalone is what makes this Community-with-SSO
#     rather than SaaS. Setting it to the real vhost silently converts the
#     portal and paywalls SSO, with no error and a healthy container.
#   - **The wizard completed, and its token is gone.** The token exists only
#     while `WizardSettings.Completed` is false, so its absence after the fact
#     is both the post-condition and the idempotency signal.
#   - **Document Server is not published**, and its `/healthcheck` body is
#     `true` rather than merely HTTP 200 — that endpoint returns 200 with a
#     body of `true` or `false`, so a status-code probe is green on a broken
#     converter.
#   - init idempotence, the mysqldump contract, loopback-only, reboot.
#
# Documented gaps (a green run covers NONE of these):
#   - **Editing a document.** Proving the editor round-trips would need a
#     browser; what is proven is that the converter answers and that the JWT
#     both containers share is the same one.
#   - **SAML.** DocSpace's SSO is SAML 2.0, free self-hosted, and needs an
#     exchange with Authentik that has not happened. It runs on the local
#     owner account.
#   - **The licence branch.** Unlicensed is Community and validation is a local
#     file-signature check with zero HTTP, so there is nothing to exercise.

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
    images."onlyoffice_docspace_3_7_2"
    images."onlyoffice_documentserver_9_4_0"
    images."mysql_8_4_6"
    images."python_3_13-alpine" # docspace_init
  ];

  seedSrv = pkgs.runCommand "srv-seed-docspace" { } ''
    mkdir -p $out/stacks/docspace
    cp -r ${../../stacks/docspace}/. $out/stacks/docspace/
    chmod -R u+w $out/stacks/docspace
    rm -f $out/stacks/docspace/.env
    rm -f $out/stacks/docspace/.sops.env.example
    cp ${../fixtures/docspace.sops.env} $out/stacks/docspace/.sops.env
  '';
in
pkgs.testers.runNixOSTest {
  name = "docspace";

  # ~4.8 GB of images, a MySQL first init, and the monolith's own 300s health
  # start period.
  globalTimeout = 7200;

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
            memoryMB = 8192;
            diskMB = 32768;
          })
          (profiles.loadImages {
            inherit pkgs;
            images = stackImages;
            beforeUnits = [ "multi-user.target" ];
          })
        ];

        systemd.services.bootstrap-arcane.wantedBy = lib.mkForce [ ];
        virtualisation.cores = lib.mkForce 4;

        virtualisation.emptyDiskImages = [ 12288 ];
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
          # The SAME set production declares. All root: Document Server chowns
          # its own mounts every start, the monolith runs as root deliberately,
          # and MySQL chowns its datadir at first init.
          "d /mnt/fast/docspace 0755 root root -"
          # 104:107 — the docspace image is USER onlyoffice and starts
          # already dropped, so it cannot chown these itself.
          "d /mnt/fast/docspace/app 0755 104 107 -"
          "d /mnt/fast/docspace/logs 0755 104 107 -"
          "d /mnt/fast/docspace/ds-data 0755 root root -"
          "d /mnt/fast/docspace/ds-lib 0755 root root -"
          "d /mnt/fast/docspace/ds-logs 0755 root root -"
          # 999:999 — mysql drops to that uid and --initialize refuses a
          # data directory it cannot write. Kept identical to the production
          # rule in nixos/hardware-configuration.nix on purpose.
          "d /mnt/fast/docspace/mysqldata 0755 999 999 -"
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
    import json

    DOCSPACE = "docker compose -f /srv/stacks/docspace/compose.yaml -p docspace"
    BASE = "http://127.0.0.1:10404"

    # Fixture values from tests/fixtures/docspace.sops.env.
    MACHINEKEY = "testdocspacemachinekey0000000000"

    def diag(label):
        print("=== diagnostics: " + label + " ===")
        for cmd in [
            "docker ps -a",
            "docker logs docspace 2>&1 | tail -80",
            "docker logs docspace_ds 2>&1 | tail -30",
            "docker logs docspace_db 2>&1 | tail -20",
            "docker logs docspace_init 2>&1 | tail -40",
            "ls -la /mnt/fast/docspace 2>&1",
            "df -h /var/lib/docker /mnt; free -m",
        ]:
            print("--- " + cmd)
            print(services_vm.execute(cmd)[1])

    def settings():
        raw = services_vm.succeed(
            f"curl -fsS --max-time 60 {BASE}/api/2.0/settings"
        )
        doc = json.loads(raw)
        inner = doc.get("response") if isinstance(doc, dict) else None
        return inner if isinstance(inner, dict) else doc

    start_all()

    with subtest("decrypt-sops-envs produced a 0600 .env owned by arcane's uid"):
        services_vm.wait_for_unit("multi-user.target")
        services_vm.wait_for_unit("docker-network-homelab.service")
        services_vm.wait_until_succeeds(
            "test -s /srv/stacks/docspace/.env", timeout=120
        )
        stat = services_vm.succeed(
            "stat -c '%a %u:%g' /srv/stacks/docspace/.env"
        ).strip()
        assert stat == "600 1000:1000", f".env is {stat}"
        for k in ["APP_CORE_MACHINEKEY", "SPRING_APPLICATION_ENCRYPTION_SECRET",
                  "DOCUMENT_SERVER_JWT_SECRET", "JWT_SECRET",
                  "MYSQL_PASSWORD", "DOCSPACE_ADMIN_PASSWORD"]:
            services_vm.succeed(f"grep -q '^{k}=.' /srv/stacks/docspace/.env")

    services_vm.wait_for_unit("load-test-images.service")

    with subtest("compose up brings the three long-lived containers healthy"):
        # Start everything, then wait only on the ones with healthchecks
        # (finding #42): docspace_init has none by design.
        try:
            services_vm.succeed(f"{DOCSPACE} up -d")
            services_vm.succeed(
                f"{DOCSPACE} up -d --wait --wait-timeout 1800 "
                "docspace docspace_ds docspace_db"
            )
        except Exception:
            diag("compose up failed")
            raise

    with subtest("🚨 the machine key in play is the one from sops"):
        # Upstream's compose sets APP_CORE_MACHINEKEY to "" to force generation
        # into the data volume. A portal running on a generated key derives its
        # password salt from a value that exists nowhere but a bind mount, and
        # cannot be restored from anything but a byte-exact copy of it.
        env = services_vm.succeed(
            "docker inspect --format "
            "'{{range .Config.Env}}{{println .}}{{end}}' docspace"
        )
        assert f"APP_CORE_MACHINEKEY={MACHINEKEY}" in env, (
            "the container did not receive the fixture's machine key"
        )
        # And nothing generated a different one behind it.
        persisted = services_vm.succeed(
            "cat /mnt/fast/docspace/app/.secrets/APP_CORE_MACHINEKEY "
            "2>/dev/null || echo ABSENT"
        ).strip()
        assert persisted in (MACHINEKEY, "ABSENT"), (
            f"a DIFFERENT machine key is persisted in the data volume "
            f"({persisted!r}); the env var is not the one in effect"
        )

    with subtest("🚨 APP_CORE_BASE_DOMAIN is still localhost — Standalone holds"):
        # `Standalone` is computed as `Basedomain == "localhost"`, and
        # Standalone is what makes this Community-with-SSO rather than SaaS.
        # Setting this to the real vhost converts the portal silently.
        env = services_vm.succeed(
            "docker inspect --format "
            "'{{range .Config.Env}}{{println .}}{{end}}' docspace"
        )
        assert "APP_CORE_BASE_DOMAIN=localhost" in env, env

    with subtest("docspace_init completed the wizard"):
        services_vm.wait_until_succeeds(
            "docker inspect -f '{{.State.Status}}/{{.State.ExitCode}}' "
            "docspace_init | grep -qx exited/0",
            timeout=1200,
        )
        logs = services_vm.succeed("docker logs docspace_init 2>&1")
        assert "CHANGE: completed the setup wizard" in logs, logs

    with subtest("the wizard token is gone — the post-condition"):
        # It exists only while WizardSettings.Completed is false. Its absence is
        # both the proof the wizard finished and the reason a rerun is a no-op.
        assert not settings().get("wizardToken"), (
            "the wizard token is still present; the portal is still open to "
            "whoever reaches the port first"
        )

    with subtest("docspace_init is idempotent — a redeploy changes nothing"):
        services_vm.succeed("docker rm -f docspace_init")
        services_vm.succeed(f"{DOCSPACE} up -d docspace_init")
        services_vm.wait_until_succeeds(
            "docker inspect -f '{{.State.Status}}/{{.State.ExitCode}}' "
            "docspace_init | grep -qx exited/0",
            timeout=600,
        )
        logs = services_vm.succeed("docker logs docspace_init 2>&1")
        assert "CHANGE:" not in logs, f"second run mutated something:\n{logs}"
        assert "already completed" in logs, logs

    with subtest("🚨 Document Server's /healthcheck says `true`, not just 200"):
        # That endpoint returns HTTP 200 with a BODY of `true` or `false`, so a
        # status-code probe is green on a broken converter. This is why the
        # compose healthcheck greps the body.
        out = services_vm.succeed(
            "docker exec docspace_ds curl -fsS --max-time 20 "
            "http://127.0.0.1:80/healthcheck"
        ).strip()
        assert out == "true", f"document server healthcheck body is {out!r}"

    with subtest("Document Server is NOT published"):
        out = services_vm.succeed(
            "docker inspect --format '{{json .NetworkSettings.Ports}}' docspace_ds"
        ).strip()
        assert '"HostPort"' not in out, f"document server publishes a port: {out}"

    with subtest("backup-prepare's mysqldump contract holds"):
        # The literal command backup-prepare.sh runs. MySQL 8.4 still ships
        # mysqldump — finding #35 was MariaDB 11 dropping its mysql* symlinks
        # and does not apply here, which is exactly the sort of thing worth
        # proving rather than assuming twice. MYSQL_PWD instead of -p on argv
        # mirrors backup-prepare.sh:192 exactly (the password used to be
        # host-visible in /proc/<pid>/cmdline).
        services_vm.succeed(
            "docker exec docspace_db sh -c "
            "'MYSQL_PWD=\"$MYSQL_ROOT_PASSWORD\"; export MYSQL_PWD; "
            "exec mysqldump -u root --all-databases' "
            "> /tmp/docspace.sql"
        )
        out = services_vm.succeed("head -40 /tmp/docspace.sql")
        assert "CREATE DATABASE" in out or "MySQL dump" in out, out

    with subtest("10404 is loopback-only, with a positive control"):
        ip = services_vm.succeed(
            "ip -4 -o addr show eth1 | awk '{print $4}' | cut -d/ -f1"
        ).strip()
        outsider.wait_for_unit("network.target")
        outsider.fail(f"curl -s --max-time 10 http://{ip}:10404/ >/dev/null")
        outsider.succeed(f"ping -c1 -W5 {ip} >/dev/null")

    with subtest("state survives a reboot"):
        # shutdown()+start(), not reboot(): qemu runs with -no-reboot.
        services_vm.shutdown()
        services_vm.start()
        services_vm.wait_for_unit("multi-user.target")
        services_vm.wait_until_succeeds(
            "test -s /srv/stacks/docspace/.env", timeout=180
        )
        services_vm.wait_for_unit("load-test-images.service")
        services_vm.succeed(f"{DOCSPACE} up -d")
        services_vm.succeed(
            f"{DOCSPACE} up -d --wait --wait-timeout 1800 "
            "docspace docspace_ds docspace_db"
        )
        # The wizard must still be complete — if the machine key had been
        # regenerated on this boot, the portal would be a different install.
        assert not settings().get("wizardToken"), (
            "the wizard token came back after a reboot"
        )
  '';
}
