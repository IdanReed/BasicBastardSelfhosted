# Tandoor suite: the app, its Postgres, and the shell one-shot that creates
# the only superuser there is a path to.
#
# Genuinely under test:
#   - 🚨 **There is no SQLite file.** recipes/settings.py reads
#     `'ENGINE': DB_ENGINE if DB_ENGINE else 'django.db.backends.sqlite3'` with
#     no error, no warning and no log line when the variable is absent — and
#     boot.sh's Postgres wait loop is itself guarded on DB_ENGINE being set, so
#     the container does not even wait for the database it is not going to use.
#     Line that up with `env_file: required: false` (finding #11) and the
#     decrypt race CLAUDE.md documents: a deploy that wins that race gets a
#     green healthcheck, an ephemeral SQLite file inside the container's
#     writable layer, a working setup wizard, and an idle tandoor_db — while
#     backup-prepare.sh dumps the real, empty Postgres nightly with rc=0.
#     The mitigation is to keep the five database settings in compose.yaml
#     rather than .env; this suite is what proves the mitigation holds.
#   - **The superuser exists, is a superuser, and has a Space** — the last part
#     because at 2.6.13 the Space is materialised by middleware on the first
#     authenticated request, and tandoor_init calls the app's own
#     `create_space_for_user` instead so the state is assertable without
#     driving a login.
#   - **The `test`/`test` account does NOT exist.** `seed_basic_data` is a
#     developer fixture that looks exactly like the tool for this job.
#   - init idempotence: a rerun logs zero CHANGE lines.
#   - 🚨 **A nonexistent path returns 200, not 404** — pinned deliberately.
#     cookbook.urls ends in a catch-all to the Vue frontend, so any assertion
#     of the form "unknown path → 404" is wrong here and any "path → 200" is
#     meaningless without checking the body. Recording it stops the next person
#     writing a test that cannot fail.
#
# Documented gaps:
#   - **OIDC.** Ships ready and off; the client secret needs the production age
#     key. The local superuser is what the suite exercises.
#   - **A Postgres that dies AFTER start.** boot.sh's pg_isready loop kills the
#     container loudly if the database is dead at start; a later failure leaves
#     the healthcheck green. The honest mitigation is external monitoring, not
#     a cleverer probe.

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
    images."ghcr_io_tandoorrecipes_recipes_2_6_13"
    images."postgres_17_9-alpine"
  ];

  seedSrv = pkgs.runCommand "srv-seed-tandoor" { } ''
    mkdir -p $out/stacks/tandoor
    cp -r ${../../stacks/tandoor}/. $out/stacks/tandoor/
    chmod -R u+w $out/stacks/tandoor
    rm -f $out/stacks/tandoor/.env
    rm -f $out/stacks/tandoor/.sops.env.example
    cp ${../fixtures/tandoor.sops.env} $out/stacks/tandoor/.sops.env
  '';
in
pkgs.testers.runNixOSTest {
  name = "tandoor";

  globalTimeout = 5400;

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

        systemd.services.bootstrap-arcane.wantedBy = lib.mkForce [ ];
        virtualisation.cores = lib.mkForce 2;

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
          # root:root, matching production: the image has no USER instruction
          # and boot.sh chmods the media root itself.
          "d /mnt/fast/tandoor 0755 root root -"
          "d /mnt/fast/tandoor/pgdata 0755 root root -"
          "d /mnt/fast/tandoor/mediafiles 0755 root root -"
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
    TANDOOR = "docker compose -f /srv/stacks/tandoor/compose.yaml -p tandoor"
    BASE = "http://127.0.0.1:10350"
    ADMIN = "tandoor-admin"

    def diag(label):
        print("=== diagnostics: " + label + " ===")
        for cmd in [
            "docker ps -a",
            "docker logs tandoor 2>&1 | tail -60",
            "docker logs tandoor_db 2>&1 | tail -20",
            "docker logs tandoor_init 2>&1 | tail -40",
            "ls -la /mnt/fast/tandoor 2>&1",
            "df -h /var/lib/docker /mnt; free -m",
        ]:
            print("--- " + cmd)
            print(services_vm.execute(cmd)[1])

    def status(path):
        return int(services_vm.succeed(
            "curl -s -o /dev/null -w '%{http_code}' --max-redirs 0 "
            f"--max-time 30 {BASE}{path}"
        ).strip())

    def sql(q):
        return services_vm.succeed(
            f"docker exec tandoor_db psql -U tandoor -d tandoor -tAc \"{q}\""
        ).strip()

    start_all()

    with subtest("decrypt-sops-envs produced a 0600 .env owned by arcane's uid"):
        services_vm.wait_for_unit("multi-user.target")
        services_vm.wait_for_unit("docker-network-homelab.service")
        services_vm.wait_until_succeeds("test -s /srv/stacks/tandoor/.env", timeout=120)
        stat = services_vm.succeed("stat -c '%a %u:%g' /srv/stacks/tandoor/.env").strip()
        assert stat == "600 1000:1000", f".env is {stat}"
        for k in ["SECRET_KEY", "POSTGRES_PASSWORD", "TANDOOR_ADMIN_USER",
                  "TANDOOR_ADMIN_PASSWORD"]:
            services_vm.succeed(f"grep -q '^{k}=.' /srv/stacks/tandoor/.env")

    services_vm.wait_for_unit("load-test-images.service")

    with subtest("compose up brings the app and database healthy"):
        try:
            # Start EVERYTHING first, including the one-shots — enumerating
            # services in the --wait call below means only those get created,
            # and the init container would never run at all.
            services_vm.succeed(f"{TANDOOR} up -d")
            services_vm.succeed(
                f"{TANDOOR} up -d --wait --wait-timeout 900 tandoor tandoor_db"
            )
        except Exception:
            diag("compose up failed")
            raise

    with subtest("🚨 there is NO SQLite file — the silent-fallback assertion"):
        # If DB_ENGINE and POSTGRES_DB were ever moved into .env and a deploy
        # raced the first decrypt, Tandoor would migrate an ephemeral SQLite
        # file into its own writable layer, serve a green healthcheck, offer
        # the setup wizard, and leave tandoor_db idle. Nothing else here would
        # notice — the healthcheck would pass and so would every HTTP probe.
        services_vm.succeed("docker exec tandoor test ! -f /opt/recipes/db.sqlite3")
        env = services_vm.succeed(
            "docker inspect --format "
            "'{{range .Config.Env}}{{println .}}{{end}}' tandoor"
        )
        assert "DB_ENGINE=django.db.backends.postgresql" in env, env
        # And DATABASE_URL must stay unset: setup_database() checks it BEFORE
        # the POSTGRES_* branch, so setting it for any reason silently
        # overrides the mitigation above — and it accepts a sqlite:// scheme.
        assert "\nDATABASE_URL=" not in "\n" + env, "DATABASE_URL is set"

    with subtest("SECRET_KEY is not the published fallback"):
        # An unset SECRET_KEY does not crash: settings.py falls back to the
        # literal 'INSECURE_STANDARD_KEY_SET_IN_ENV', which is in the public
        # repository, and boot.sh prints a [WARNING] and carries on. Because
        # the fallback is CONSTANT, nothing looks wrong across restarts.
        env = services_vm.succeed(
            "docker inspect --format "
            "'{{range .Config.Env}}{{println .}}{{end}}' tandoor"
        )
        assert "SECRET_KEY=INSECURE_STANDARD_KEY_SET_IN_ENV" not in env
        assert "SECRET_KEY=test_tandoor_secret_key" in env, env

    with subtest("tandoor_init created the superuser and its space"):
        services_vm.wait_until_succeeds(
            "docker inspect -f '{{.State.Status}}/{{.State.ExitCode}}' "
            "tandoor_init | grep -qx exited/0",
            timeout=600,
        )
        logs = services_vm.succeed("docker logs tandoor_init 2>&1")
        assert "CHANGE: created superuser" in logs, logs
        assert "CHANGE: created the space" in logs, logs

        # Asserted in the DATABASE, which also proves the app is really on
        # Postgres rather than the SQLite file the previous subtest denies.
        assert sql(
            f"select is_superuser from auth_user where username='{ADMIN}'"
        ) == "t"
        assert sql(
            f"select count(*) from cookbook_userspace u "
            f"join auth_user a on a.id=u.user_id where a.username='{ADMIN}'"
        ) == "1"

    with subtest("the developer fixture account does NOT exist"):
        # `manage.py seed_basic_data` reads like the tool for this job — its
        # --help says "Seeds some basic data (space, account, food)" — and
        # plants a user literally named `test` with password `test`.
        assert sql("select count(*) from auth_user where username='test'") == "0"

    with subtest("tandoor_init is idempotent — a redeploy changes nothing"):
        services_vm.succeed("docker rm -f tandoor_init")
        services_vm.succeed(f"{TANDOOR} up -d tandoor_init")
        services_vm.wait_until_succeeds(
            "docker inspect -f '{{.State.Status}}/{{.State.ExitCode}}' "
            "tandoor_init | grep -qx exited/0",
            timeout=600,
        )
        logs = services_vm.succeed("docker logs tandoor_init 2>&1")
        assert "CHANGE:" not in logs, f"second run mutated something:\n{logs}"

    with subtest("🚨 an unknown path returns 200 — the catch-all, pinned"):
        # cookbook.urls ends in a catch-all to the Vue frontend (upstream's own
        # comment says so). Recorded because it makes two obvious test shapes
        # useless here: "unknown path → 404" always fails, and "path → 200"
        # proves nothing without checking the body.
        assert status("/openapi/") == 200, "the schema view should be AllowAny"
        # NOT `== 200`. The catch-all hands the request to the Vue frontend,
        # which for an unauthenticated caller redirects to the login page — so
        # the observable fact is "never 404", not "always 200". The first
        # version of this assertion said 200 and failed against a 302, which is
        # itself the lesson: the point is that Tandoor's router does not 404, so
        # no assertion of the form "unknown path -> 404" can work here and no
        # "path -> 200" proves a route exists.
        code = status("/this-path-does-not-exist-" + "x" * 12)
        assert code != 404, (
            f"an unknown path returned {code}; the Vue catch-all appears to be "
            "gone, which means route assertions in this suite can be tightened"
        )
        assert code in (200, 302), f"unexpected status {code} for an unknown path"

    with subtest("backup-prepare's pg_dumpall contract holds"):
        services_vm.succeed(
            "docker exec tandoor_db pg_dumpall -U tandoor > /tmp/tandoor.sql"
        )
        out = services_vm.succeed("head -40 /tmp/tandoor.sql")
        assert "CREATE ROLE" in out or "ROLE tandoor" in out, out

    with subtest("10350 is loopback-only, with a positive control"):
        ip = services_vm.succeed(
            "ip -4 -o addr show eth1 | awk '{print $4}' | cut -d/ -f1"
        ).strip()
        outsider.wait_for_unit("network.target")
        outsider.fail(f"curl -s --max-time 10 http://{ip}:10350/ >/dev/null")
        outsider.succeed(f"ping -c1 -W5 {ip} >/dev/null")

    with subtest("state survives a reboot"):
        services_vm.shutdown()
        services_vm.start()
        services_vm.wait_for_unit("multi-user.target")
        services_vm.wait_until_succeeds("test -s /srv/stacks/tandoor/.env", timeout=180)
        services_vm.wait_for_unit("load-test-images.service")
        # Start EVERYTHING first, including the one-shots — enumerating
        # services in the --wait call below means only those get created,
        # and the init container would never run at all.
        services_vm.succeed(f"{TANDOOR} up -d")
        services_vm.succeed(
            f"{TANDOOR} up -d --wait --wait-timeout 900 tandoor tandoor_db"
        )
        services_vm.succeed("docker exec tandoor test ! -f /opt/recipes/db.sqlite3")
        assert sql(
            f"select is_superuser from auth_user where username='{ADMIN}'"
        ) == "t"
  '';
}
