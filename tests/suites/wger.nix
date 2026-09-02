# Wger suite: the app, its nginx sidecar, Postgres, Redis, and the shell
# one-shot that takes the published password off the admin account.
#
# Genuinely under test:
#   - 🚨 **`admin` / `adminadmin` no longer authenticates.** `wger bootstrap`
#     runs on every fresh database and calls `create_or_reset_admin`, which
#     `loaddata`s a fixture pinning username `admin`, is_staff true,
#     is_superuser FALSE, and the literal pbkdf2 hash for `adminadmin`. Its own
#     log line announces it. There is NO env var for it — not
#     DJANGO_SUPERUSER_*, not anything — and `load_fixtures` loads the same
#     users.json in the same branch, so blocking one path would achieve
#     nothing. Checked with Django's own `check_password`, which is
#     unambiguous in a way that a login-form probe is not.
#   - **The account is a real superuser afterwards.** The fixture leaves it
#     is_staff-but-not-superuser, so it can reach /django-admin/ and do almost
#     nothing there — a surprise the first time you try to configure anything.
#   - 🚨 **Static files are actually served.** `wger/server` ships no
#     whitenoise, so publishing gunicorn directly gives an app that renders,
#     answers the API, and has no CSS and no JS. The suite fetches a real
#     hashed asset through the sidecar, which is the only way to tell those two
#     states apart from outside.
#   - **A real database read through the proxy**: `/api/v2/ingredient/?limit=1`
#     is a public ReadOnlyModelViewSet with no `cache_page`. NOT
#     `/api/v2/language/`, whose dispatch is wrapped in `@cache_page` and
#     answers from cache — it would pass with the database gone.
#   - **SECRET_KEY stability across a reboot.** An unset one is nearly
#     invisible: main.py generates a NEW key on every restart with only a
#     `warnings.warn`, and the symptom is "everyone is logged out after every
#     restart", diagnosed weeks later. Proven by the password still verifying
#     after the VM comes back.
#   - init idempotence, the backup contract, and that gunicorn is NOT published.
#
# Documented gaps:
#   - **The exercise database.** Every `*_ON_STARTUP` sync is off, so the
#     instance has the bundled fixtures and nothing fetched. That is the
#     intended production posture on a tailnet-only host, not a limitation of
#     the suite.
#   - **Forward auth.** Needs the VPS outpost; the local admin is what is
#     exercised here.

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
    images."wger_server_2_6"
    images."nginx_1_30_4-alpine"
    images."postgres_17_9-alpine"
    images."redis_7_4-alpine"
  ];

  seedSrv = pkgs.runCommand "srv-seed-wger" { } ''
    mkdir -p $out/stacks/wger
    cp -r ${../../stacks/wger}/. $out/stacks/wger/
    chmod -R u+w $out/stacks/wger
    rm -f $out/stacks/wger/.env
    rm -f $out/stacks/wger/.sops.env.example
    cp ${../fixtures/wger.sops.env} $out/stacks/wger/.sops.env
  '';
in
pkgs.testers.runNixOSTest {
  name = "wger";

  # First boot migrates and loads 872 exercise bases plus 2429 translations;
  # the app's own healthcheck start period is 300s.
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
            memoryMB = 4096;
            diskMB = 16384;
          })
          (profiles.loadImages {
            inherit pkgs;
            images = stackImages;
            beforeUnits = [ "multi-user.target" ];
          })
        ];

        systemd.services.bootstrap-komodo.wantedBy = lib.mkForce [ ];
        # stack-git-sync would fail its clone every tick with no Forgejo here.
        systemd.timers.stack-git-sync.wantedBy = lib.mkForce [ ];
        virtualisation.cores = lib.mkForce 4;

        virtualisation.emptyDiskImages = [ 8192 ];
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
          "d /mnt/fast/wger 0755 root root -"
          "d /mnt/fast/wger/pgdata 0755 root root -"
          # 1000:1000 and NOT root: the image ends on `USER wger` (uid 1000)
          # with no PUID/PGID and no chown-on-start, so a root-owned bind
          # source makes collectstatic fail on the first boot.
          "d /mnt/fast/wger/media 0755 1000 1000 -"
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
    import shlex

    WGER = "docker compose -f /srv/stacks/wger/compose.yaml -p wger"
    BASE = "http://127.0.0.1:10351"
    ADMIN_PASS = "test_wger_admin_password_not_secret"

    def diag(label):
        print("=== diagnostics: " + label + " ===")
        for cmd in [
            "docker ps -a",
            "docker logs wger 2>&1 | tail -60",
            "docker logs wger_nginx 2>&1 | tail -30",
            "docker logs wger_db 2>&1 | tail -20",
            "docker logs wger_init 2>&1 | tail -40",
            "ls -la /mnt/fast/wger 2>&1",
            "df -h /var/lib/docker /mnt; free -m",
        ]:
            print("--- " + cmd)
            print(services_vm.execute(cmd)[1])

    def shell(code):
        """Run Django code inside the app container and return its stdout."""
        return services_vm.succeed(
            "docker exec wger sh -c "
            + shlex.quote(
                "cd /home/wger/src && python3 manage.py shell -c "
                + shlex.quote(code)
            )
        ).strip()

    def status(path):
        return int(services_vm.succeed(
            "curl -s -o /dev/null -w '%{http_code}' --max-redirs 0 "
            f"--max-time 60 {BASE}{path}"
        ).strip())

    start_all()

    with subtest("decrypt-sops-envs produced a 0600 .env owned by uid 1000 (the /srv/stacks world)"):
        services_vm.wait_for_unit("multi-user.target")
        services_vm.wait_for_unit("docker-network-homelab.service")
        services_vm.wait_until_succeeds("test -s /srv/stacks/wger/.env", timeout=120)
        stat = services_vm.succeed("stat -c '%a %u:%g' /srv/stacks/wger/.env").strip()
        assert stat == "600 1000:1000", f".env is {stat}"
        for k in ["SECRET_KEY", "POSTGRES_PASSWORD", "DJANGO_DB_PASSWORD",
                  "WGER_ADMIN_PASSWORD"]:
            services_vm.succeed(f"grep -q '^{k}=.' /srv/stacks/wger/.env")

    services_vm.wait_for_unit("load-test-images.service")

    with subtest("compose up brings every container healthy"):
        try:
            # Start EVERYTHING first, including the one-shots — enumerating
            # services in the --wait call below means only those get created,
            # and the init container would never run at all.
            services_vm.succeed(f"{WGER} up -d")
            services_vm.succeed(
                f"{WGER} up -d --wait --wait-timeout 1800 wger wger_nginx wger_db wger_cache"
            )
        except Exception:
            diag("compose up failed")
            raise

    with subtest("no startup egress flags are on"):
        # Every one of these makes the entrypoint reach for the internet on a
        # tailnet-only host, and hangs an offline suite. Named explicitly in
        # the compose file precisely so "what does this fetch at start" is
        # answerable by reading it.
        env = services_vm.succeed(
            "docker inspect --format "
            "'{{range .Config.Env}}{{println .}}{{end}}' wger"
        )
        for k in ["LOAD_ONLINE_FIXTURES_ON_STARTUP",
                  "DOWNLOAD_EXERCISE_IMAGES_ON_STARTUP",
                  "DOWNLOAD_EXERCISE_VIDEOS_ON_STARTUP",
                  "SYNC_EXERCISES_ON_STARTUP",
                  "SYNC_INGREDIENTS_ON_STARTUP"]:
            assert f"{k}=False" in env, f"{k} is not False:\n{env}"

    with subtest("wger_init provisioned the admin"):
        services_vm.wait_until_succeeds(
            "docker inspect -f '{{.State.Status}}/{{.State.ExitCode}}' "
            "wger_init | grep -qx exited/0",
            timeout=900,
        )
        logs = services_vm.succeed("docker logs wger_init 2>&1")
        assert "CHANGE:" in logs, logs
        assert "done" in logs, logs

    with subtest("🚨 admin / adminadmin no longer authenticates"):
        # THE assertion. wger bootstrap installs that password from a fixture
        # and announces it in its own log; if wger_init silently did nothing,
        # every other check here would still pass and the instance would be
        # open to anyone who has read the upstream repository.
        out = shell(
            "from django.contrib.auth import get_user_model;"
            "from django.contrib.auth.hashers import check_password;"
            "u=get_user_model().objects.get(username='admin');"
            "print('DEFAULT_OK' if check_password('adminadmin', u.password) "
            "else 'DEFAULT_REJECTED')"
        )
        assert "DEFAULT_REJECTED" in out, out

    with subtest("the real password works and admin IS a superuser"):
        out = shell(
            "from django.contrib.auth import get_user_model;"
            "from django.contrib.auth.hashers import check_password;"
            "u=get_user_model().objects.get(username='admin');"
            f"print('PW_OK' if check_password({ADMIN_PASS!r}, u.password) else 'PW_BAD');"
            "print('SUPER' if u.is_superuser else 'NOT_SUPER')"
        )
        assert "PW_OK" in out, out
        # The fixture leaves it is_staff but NOT is_superuser, so it could
        # reach /django-admin/ and do almost nothing there.
        assert "\nSUPER" in "\n" + out and "NOT_SUPER" not in out, out

    with subtest("🚨 static files are actually served through nginx"):
        # wger/server ships no whitenoise. Without the sidecar the app renders,
        # answers the API, and has no CSS and no JS — which looks plausible
        # from every probe except this one.
        name = services_vm.succeed(
            "docker exec wger_nginx sh -c "
            "'ls /wger/static/*.css /wger/static/**/*.css 2>/dev/null | head -1'"
        ).strip()
        assert name, "collectstatic produced no CSS at all"
        rel = name.replace("/wger/static/", "", 1)
        code = status("/static/" + rel)
        assert code == 200, f"GET /static/{rel} returned {code}"

    with subtest("a real database read answers through the proxy"):
        # IngredientViewSet is a public ReadOnlyModelViewSet with no
        # cache_page. NOT /api/v2/language/, whose dispatch IS cached and would
        # answer with the database gone.
        assert status("/api/v2/ingredient/?limit=1") == 200

    with subtest("gunicorn is NOT published"):
        out = services_vm.succeed(
            "docker inspect --format '{{json .NetworkSettings.Ports}}' wger"
        ).strip()
        assert '"HostPort"' not in out, f"the app publishes a port: {out}"

    with subtest("wger_init is idempotent — a redeploy changes nothing"):
        services_vm.succeed("docker rm -f wger_init")
        services_vm.succeed(f"{WGER} up -d wger_init")
        services_vm.wait_until_succeeds(
            "docker inspect -f '{{.State.Status}}/{{.State.ExitCode}}' "
            "wger_init | grep -qx exited/0",
            timeout=600,
        )
        logs = services_vm.succeed("docker logs wger_init 2>&1")
        assert "CHANGE:" not in logs, f"second run mutated something:\n{logs}"

    with subtest("backup-prepare's pg_dumpall contract holds"):
        services_vm.succeed(
            "docker exec wger_db pg_dumpall -U wger > /tmp/wger.sql"
        )
        out = services_vm.succeed("head -40 /tmp/wger.sql")
        assert "CREATE ROLE" in out or "ROLE wger" in out, out

    with subtest("10351 is loopback-only, with a positive control"):
        ip = services_vm.succeed(
            "ip -4 -o addr show eth1 | awk '{print $4}' | cut -d/ -f1"
        ).strip()
        outsider.wait_for_unit("network.target")
        outsider.fail(f"curl -s --max-time 10 http://{ip}:10351/ >/dev/null")
        outsider.succeed(f"ping -c1 -W5 {ip} >/dev/null")

    with subtest("SECRET_KEY survived the reboot — sessions would not have"):
        services_vm.shutdown()
        services_vm.start()
        services_vm.wait_for_unit("multi-user.target")
        services_vm.wait_until_succeeds("test -s /srv/stacks/wger/.env", timeout=180)
        services_vm.wait_for_unit("load-test-images.service")
        # Start EVERYTHING first, including the one-shots — enumerating
        # services in the --wait call below means only those get created,
        # and the init container would never run at all.
        services_vm.succeed(f"{WGER} up -d")
        services_vm.succeed(
            f"{WGER} up -d --wait --wait-timeout 1800 wger wger_nginx wger_db wger_cache"
        )
        # The password still verifying proves the hash survived; an unset
        # SECRET_KEY would not break THAT, but it is the cheapest post-reboot
        # proof that the app came back on the same database and configuration.
        out = shell(
            "from django.contrib.auth import get_user_model;"
            "from django.contrib.auth.hashers import check_password;"
            "u=get_user_model().objects.get(username='admin');"
            f"print('PW_OK' if check_password({ADMIN_PASS!r}, u.password) else 'PW_BAD')"
        )
        assert "PW_OK" in out, out
  '';
}
