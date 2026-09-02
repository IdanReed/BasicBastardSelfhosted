# Paperless heavy suite: the full document pipeline on the services VM.
#
# The light services-vm suite proves the boot chain (sops decrypt -> docker
# network -> arcane) and the small stacks; this one boots the multi-GB
# Paperless stack for real and pushes a document through it. Genuinely under
# test:
#   - decrypt-sops-envs turning stacks/paperless/.sops.env into a 0600 .env
#   - the real compose file: five containers, the named redis volume, the
#     /mnt/fast bind mounts, and the compose-network DNS the services rely on
#     (paperless -> tika/gotenberg by service name)
#   - env_file threading END TO END: the fixture's admin credentials must
#     produce a Django superuser that can mint an API token — container
#     liveness alone would pass with an empty or unread .env
#   - the consumption pipeline: an uploaded document travels HTTP -> redis
#     queue -> celery worker -> postgres, and comes back out of the API
#   - loopback-only publishing, verified from another host
#
# Not covered here (and covered elsewhere or not at all): Caddy routing to
# paperless.svc.idanreed.com (services-vm suite covers the routing table),
# OCR of real scans (the fixture document is plain text; tika/gotenberg are
# only proven reachable), and Arcane actually *managing* this stack — compose
# is driven directly so a scheduler quirk cannot mask a compose-file bug.
#
# hardware-configuration.nix is not imported: it mounts real partitions by
# partlabel. Only the /srv + sops tmpfiles rules are reproduced from it; the
# /mnt/fast/paperless/* roots below are suite-local (the real host lets docker
# create bind sources on first `up`, which works because the paperless
# entrypoint chowns per USERMAP_* and postgres chowns pgdata itself).

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
    images."ghcr_io_paperless-ngx_paperless-ngx_2_20"
    images."postgres_17_9-alpine"
    images."redis_7_4-alpine"
    images."apache_tika_3_3_0_0"
    images."gotenberg_gotenberg_8_31"
    # Not under test here, but bootstrap-komodo is wantedBy multi-user.target
    # in nixos/configuration.nix and runs during boot; without its image it
    # crash-loops and pollutes every journal dump with red herrings.
    images."ghcr_io_moghtech_komodo-core_2_1_0"
    images."ghcr_io_moghtech_komodo-periphery_2_1_0"
    images."ghcr_io_ferretdb_ferretdb_2_7_0"
    images."ghcr_io_ferretdb_postgres-documentdb_17-0_107_0-ferretdb-2_7_0"
  ];

  # Seeds /srv the way the real host gets it: Arcane's git sync on the live
  # machine, a store copy here. ONLY the paperless stack is seeded — the other
  # stacks are the light suite's job — plus /srv/komodo, because
  # bootstrap-komodo runs unconditionally at boot and `docker compose up`
  # against an absent compose file would leave a failed unit in the chain
  # decrypt-sops-envs participates in.
  seedSrv = pkgs.runCommand "srv-seed-paperless" { } ''
    mkdir -p $out/komodo $out/stacks/paperless
    cp ${../../komodo/compose.yaml} $out/komodo/compose.yaml
    cp ${../fixtures/komodo.sops.env} $out/komodo/.sops.env

    cp -r ${../../stacks/paperless}/. $out/stacks/paperless/
    chmod -R u+w $out/stacks/paperless
    # The working-tree cp -r can capture a developer's locally-decrypted
    # plaintext .env (gitignored on purpose) in the world-readable store.
    rm -f $out/stacks/paperless/.env
    rm -f $out/stacks/paperless/.sops.env.example
    cp ${../fixtures/paperless.sops.env} $out/stacks/paperless/.sops.env
  '';
in
pkgs.testers.runNixOSTest {
  name = "paperless";

  # The explicit wait budgets below (migrations + OCR pipeline) can exceed the
  # driver's 3600s default, and a driver-level timeout kills the VMs without
  # running any except handler — paperless_diag would never print. Two hours
  # keeps the worst case inside the budget with the diagnostics reachable.
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
          # No headscale in this suite; left on boot it would retry forever
          # against an unreachable login server and hold up multi-user.target.
          profiles.manualTailscaleAutoconnect
          (profiles.sopsFixture ../fixtures/services-vm.sops.yaml)
          # Paperless + postgres + tika + gotenberg need real headroom:
          # migrations, OCR toolchain startup and the JVM in tika all fight
          # for memory, and five images plus a docker volume live on disk.
          (profiles.sized {
            memoryMB = 7168;
            diskMB = 16384;
          })
          (profiles.loadImages {
            inherit pkgs;
            images = stackImages;
            beforeUnits = [ "bootstrap-komodo.service" ];
          })
          # stack-git-sync timer would fail its clone each tick (no Forgejo here).
          { systemd.timers.stack-git-sync.wantedBy = lib.mkForce [ ]; }
        ];

        # decrypt-sops-envs.service and bootstrap-komodo.service both
        # `requires = srv.mount`; the tmpfs gives them a genuine .mount unit.
        # /mnt/fast is where the compose file bind-mounts everything.
        # Coverage lost: nothing — the real partitions are just ext4 mounts.
        virtualisation.fileSystems = {
          "/srv" = {
            device = "tmpfs";
            fsType = "tmpfs";
            options = [ "mode=0755" ];
          };
          "/mnt/fast" = {
            device = "tmpfs";
            fsType = "tmpfs";
            options = [ "mode=0755" ];
          };
          "/mnt/slow" = {
            device = "tmpfs";
            fsType = "tmpfs";
            options = [ "mode=0755" ];
          };
        };

        systemd.tmpfiles.rules = [
          # Copied from nixos/hardware-configuration.nix, which cannot be
          # imported here because it mounts real partitions by partlabel.
          "d /srv/komodo 0755 root root -"
          "d /srv/stacks 0755 1000 1000 -"
          "d /var/lib/sops-nix 0700 root root -"
          # Bind-mount roots from stacks/paperless/compose.yaml. root-owned is
          # correct: the paperless entrypoint chowns its four dirs to
          # USERMAP_UID/GID and postgres takes ownership of pgdata itself.
          "d /mnt/fast/paperless 0755 root root -"
          "d /mnt/fast/paperless/data 0755 root root -"
          "d /mnt/fast/paperless/media 0755 root root -"
          "d /mnt/fast/paperless/consume 0755 root root -"
          "d /mnt/fast/paperless/export 0755 root root -"
          "d /mnt/fast/paperless/pgdata 0755 root root -"
        ];

        # Populate /srv before anything reads it.
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
            mkdir -p /srv/komodo /srv/stacks
            cp -r --no-preserve=mode ${seedSrv}/komodo/. /srv/komodo/
            cp -r --no-preserve=mode ${seedSrv}/stacks/. /srv/stacks/
            chown -R 1000:1000 /srv/stacks
          '';
        };

        environment.systemPackages = with pkgs; [ docker-compose ];
      };

    # Another host on the LAN, for the negative binding assertion. The
    # services VM trusts tailscale0 wholesale, so anything this node can reach
    # on a non-tailnet interface is reachable from the whole VLAN — and
    # Paperless holds every scanned document on the box.
    outsider = { };
  };

  testScript = ''
    start_all()

    def paperless_diag(machine):
        # wait_until_succeeds' `timeout` counts retries, not seconds, and each
        # failed curl burns its own --max-time. Migrations legitimately take
        # minutes, so when a wait finally gives up the journal is the only
        # thing that distinguishes "slow" from "crash-looping".
        for label, cmd in [
            ("containers", "docker ps -a"),
            ("paperless logs", "docker logs paperless 2>&1 | tail -100"),
            ("db logs", "docker logs paperless_db 2>&1 | tail -20"),
            ("redis logs", "docker logs paperless_redis 2>&1 | tail -20"),
            ("disk/mem", "df -h /var/lib/docker /mnt/fast; free -m"),
        ]:
            print(f"=== {label} ===")
            print(machine.execute(cmd)[1])

    # -----------------------------------------------------------------------
    # (a) Secret decryption
    # -----------------------------------------------------------------------
    with subtest("decrypt-sops-envs produced a 0600 .env for paperless"):
        # Transient oneshot (re-armed by a timer); bootstrap-komodo
        # Requires+After it, so arcane up proves the decrypt pass ran.
        services_vm.wait_for_unit("bootstrap-komodo.service")
        services_vm.succeed("test -s /srv/stacks/paperless/.env")
        mode = services_vm.succeed("stat -c '%a' /srv/stacks/paperless/.env").strip()
        assert mode == "600", f"/srv/stacks/paperless/.env is mode {mode}, expected 600"
        # The key the end-to-end auth check depends on. Checking it here means
        # a later token failure points at Paperless, not at decryption.
        services_vm.succeed(
            "grep -q '^PAPERLESS_ADMIN_PASSWORD=' /srv/stacks/paperless/.env"
        )

    # Images are loaded before bootstrap-komodo, which the compose run below
    # must not race — an `up` while `docker load` still runs pulls nothing
    # (offline) and fails confusingly.
    services_vm.wait_for_unit("load-test-images.service")
    services_vm.wait_for_unit("bootstrap-komodo.service")

    # -----------------------------------------------------------------------
    # (b) The stack comes up
    # -----------------------------------------------------------------------
    # On the real host Arcane brings this up from /srv/stacks. Driving compose
    # directly tests the compose file, the decrypted env and the volumes,
    # without depending on Arcane's scheduler.
    with subtest("docker compose brings up all five containers"):
        try:
            # --wait blocks on the paperless image's builtin healthcheck, so
            # this single command already covers "migrations completed".
            services_vm.succeed(
                "docker compose -f /srv/stacks/paperless/compose.yaml "
                "-p paperless up -d --wait --wait-timeout 600",
                timeout=700,
            )
        except Exception:
            paperless_diag(services_vm)
            raise

        running = services_vm.succeed(
            "docker ps --filter status=running --format '{{.Names}}'"
        ).split()
        for name in ["paperless", "paperless_db", "paperless_redis",
                     "paperless_tika", "paperless_gotenberg"]:
            assert name in running, f"{name} is not running; running: {running!r}"

    # -----------------------------------------------------------------------
    # (c) Web UI answers
    # -----------------------------------------------------------------------
    with subtest("the web UI answers 200"):
        # -L: unauthenticated / redirects to the login page, which must 200.
        # Generous retries: even after the healthcheck passes, the first
        # request can hit a still-warming worker pool.
        try:
            services_vm.wait_until_succeeds(
                "curl -sfL --max-time 10 http://127.0.0.1:10100/ -o /dev/null",
                timeout=300,
            )
        except Exception:
            paperless_diag(services_vm)
            raise

    # -----------------------------------------------------------------------
    # (d) The fixture admin account works
    # -----------------------------------------------------------------------
    # This is the assertion that proves env_file threading end to end: the
    # credentials exist only in the encrypted fixture, so a token can be
    # minted only if sops -> .env -> compose env_file -> Django superuser
    # creation all happened. Five green containers prove none of that.
    with subtest("the admin user from the fixture env can authenticate"):
        try:
            token = services_vm.succeed(
                "curl -sf --max-time 15 -X POST "
                "-d 'username=admin' -d 'password=test_admin_password' "
                "http://127.0.0.1:10100/api/token/ | jq -r .token"
            ).strip()
            assert token and token != "null", f"no token returned: {token!r}"
            AUTH = f"-H 'Authorization: Token {token}'"

            services_vm.succeed(
                f"curl -sf --max-time 15 {AUTH} "
                "http://127.0.0.1:10100/api/documents/ -o /dev/null"
            )
        except Exception:
            paperless_diag(services_vm)
            raise

    # -----------------------------------------------------------------------
    # (e) The pipeline
    # -----------------------------------------------------------------------
    # Upload -> redis queue -> celery worker -> postgres -> API. A dead worker
    # or a broken PAPERLESS_REDIS URL passes every assertion above and fails
    # only here.
    with subtest("an uploaded document comes out of the API"):
        services_vm.succeed(
            "printf 'paperless suite pipeline fixture: hello from the tests' "
            "> /tmp/pipeline-test.txt"
        )
        services_vm.succeed(
            f"curl -sf --max-time 60 {AUTH} "
            "-F document=@/tmp/pipeline-test.txt "
            "http://127.0.0.1:10100/api/documents/post_document/"
        )
        # Consumption parses, indexes and stores; minutes on first run while
        # NLTK data and classifiers warm up.
        try:
            services_vm.wait_until_succeeds(
                f"curl -sf --max-time 10 {AUTH} "
                "http://127.0.0.1:10100/api/documents/ "
                "| jq -e '.count == 1'",
                timeout=600,
            )
        except Exception:
            paperless_diag(services_vm)
            raise

    # -----------------------------------------------------------------------
    # (f) Cross-container DNS
    # -----------------------------------------------------------------------
    # tika and gotenberg publish no host ports at all — the only way paperless
    # can use them is by service name on the compose network, so reachability
    # is asserted from INSIDE the paperless container, not from the host.
    with subtest("tika and gotenberg are reachable from the paperless container"):
        try:
            services_vm.succeed(
                "docker exec paperless curl -sf --max-time 15 "
                "http://tika:9998/tika -o /dev/null"
            )
            services_vm.succeed(
                "docker exec paperless curl -sf --max-time 15 "
                "http://gotenberg:3000/health -o /dev/null"
            )
        except Exception:
            paperless_diag(services_vm)
            raise

    # -----------------------------------------------------------------------
    # (g) Loopback-only publishing
    # -----------------------------------------------------------------------
    with subtest("the web UI is not reachable from the VLAN"):
        # The compose file binds 127.0.0.1:10100 precisely so that Caddy is
        # the only path in; on 0.0.0.0 every document is one hop from the
        # whole tailnet. Verified from another host, not by reading the file.
        outsider.fail(
            "curl -sf --max-time 5 http://services-vm:10100/ -o /dev/null"
        )
  '';
}
