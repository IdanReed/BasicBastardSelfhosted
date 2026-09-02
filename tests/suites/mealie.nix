# Mealie suite: the app, its one-shot init, and the two claims the bake-off
# marked ⚠ Unverified — both now verified in source and asserted here at
# runtime.
#
# Genuinely under test:
#   - 🚨 **The published admin credential is DEAD.** v3 pre-creates an ADMIN
#     at first boot — changeme@example.com / MyPassword, username `admin`,
#     from settings.py's `_DEFAULT_EMAIL`/`_DEFAULT_PASSWORD`, which are
#     pydantic PRIVATE attrs ("should no longer be set by end users"): the
#     env override of the v1 era is GONE. mealie_init retires the account via
#     the REST API; this suite proves the default login answers 401 and the
#     real admin's answers 200.
#   - 🚨 **The database is THE sqlite file on the bind mount** — by decision,
#     not by fallback. Mealie's engine switch (db_providers.py) maps ANY
#     value except the exact string `postgres` — unset, empty, the typo
#     `postgresql` — to sqlite with no log line, and its PostgresProvider
#     defaults the password to the literal "mealie". Deliberate sqlite makes
#     the fallback state and the intended state the same persistent file, so
#     the finding-#11 decrypt race has nothing to corrupt. Asserted by
#     reading the API's user back OUT of /mnt/fast/mealie/mealie.db with
#     sqlite3 on the HOST — the same anti-phantom shape as tandoor's
#     "there is no SQLite file", pointed the other way.
#   - **backup-prepare's sqlite_backup contract holds**: a live `.backup` of
#     /mnt/fast/mealie/mealie.db produces a non-empty database, and the
#     token-signing secrets (.secret/.session_secret) sit in the same
#     backed-up directory.
#   - **init idempotence**: a rerun logs zero CHANGE lines.
#   - **Signup is closed** (/api/app/about says allowSignup=false) and
#     **10352 is loopback-only**, with a positive control.
#
# Documented gaps:
#   - **OIDC.** Config-ready and off; the client secret needs the production
#     age key. Discovery was verified LAZY in source (authlib
#     server_metadata_url — no boot-time fetch), but no IdP runs here.
#   - **The healthcheck after start.** /api/app/about really queries the DB
#     (verified in app_about.py), but sqlite cannot "go down" separately, so
#     the interesting failure is disk-full — not reproduced here. Gatus
#     probes the same honest path in production.

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
    images."ghcr_io_mealie-recipes_mealie_v3_24_0"
  ];

  seedSrv = pkgs.runCommand "srv-seed-mealie" { } ''
    mkdir -p $out/stacks/mealie
    cp -r ${../../stacks/mealie}/. $out/stacks/mealie/
    chmod -R u+w $out/stacks/mealie
    # A developer's locally-decrypted plaintext .env is gitignored but would
    # still be captured by cp -r into the world-readable store.
    rm -f $out/stacks/mealie/.env
    rm -f $out/stacks/mealie/.sops.env.example $out/stacks/mealie/.sops.env
    cp ${../fixtures/mealie.sops.env} $out/stacks/mealie/.sops.env
  '';

  # /mnt tmpfiles rules from the SAME generated file the real host imports
  # (nixos/stack-dirs.nix), never hand-copied — the beszel suite's pattern.
  # If this throws, run nixos/generate-stack-dirs.sh: the mealie compose
  # binds /mnt/fast/mealie and the generated file has not caught up.
  stackMntRoots = [ "/mnt/fast/mealie" ];
  stackDirRules = (import ../../nixos/stack-dirs.nix).systemd.tmpfiles.rules;
  rulePath = r: lib.elemAt (lib.splitString " " r) 1;
  missingRoots = lib.filter (root: !(lib.any (r: rulePath r == root) stackDirRules)) stackMntRoots;
  mntRules =
    if missingRoots == [ ] then
      lib.filter (
        r: lib.any (root: root == rulePath r || lib.hasPrefix (root + "/") (rulePath r)) stackMntRoots
      ) stackDirRules
    else
      throw (
        "mealie suite: nixos/stack-dirs.nix has no rule for "
        + lib.concatStringsSep ", " missingRoots
        + " — re-run nixos/generate-stack-dirs.sh or fix stackMntRoots"
      );
in
pkgs.testers.runNixOSTest {
  name = "mealie";

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
        # The new stack-git-sync timer would fail its clone every tick with no Forgejo here.
        systemd.timers.stack-git-sync.wantedBy = lib.mkForce [ ];
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

        # /mnt/fast/mealie comes from generated nixos/stack-dirs.nix (see the
        # let-binding); only test-only rules and the tier roots (real
        # filesystems on the host, one disk here) are literal.
        systemd.tmpfiles.rules = [
          "d /srv/stacks 0755 1000 1000 -"
          "d /var/lib/sops-nix 0700 root root -"
          "d /mnt/fast 0755 root root -"
          "d /mnt/slow 0755 root root -"
        ]
        ++ mntRules;

        systemd.services.seed-srv = {
          description = "Seed /srv with the mealie stack (test only)";
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

        environment.systemPackages = with pkgs; [
          docker-compose
          jq
          sqlite
        ];
      };

    outsider = { };
  };

  testScript = ''
    import json

    MEALIE = "docker compose -f /srv/stacks/mealie/compose.yaml -p mealie"
    BASE = "http://127.0.0.1:10352"
    DB = "/mnt/fast/mealie/mealie.db"

    # Must match tests/fixtures/mealie.sops.env exactly.
    ADMIN_USER = "mealie-admin"
    ADMIN_EMAIL = "test-mealie@example.invalid"
    ADMIN_PASSWORD = "test_mealie_admin_password_not_secret"

    # The published boot-time default (v3.24.0 settings.py private attrs).
    DEFAULT_EMAIL = "changeme@example.com"
    DEFAULT_PASSWORD = "MyPassword"

    def diag(label):
        print("=== diagnostics: " + label + " ===")
        for cmd in [
            "docker ps -a",
            "docker logs mealie 2>&1 | tail -60",
            "docker logs mealie_init 2>&1 | tail -40",
            "ls -la /mnt/fast/mealie 2>&1",
            "df -h /var/lib/docker /mnt; free -m",
        ]:
            print("--- " + cmd)
            print(services_vm.execute(cmd)[1])

    def login_code(identity, password):
        # /api/auth/token takes FORM data; `username` accepts the email.
        return int(services_vm.succeed(
            "curl -s -o /dev/null -w '%{http_code}' --max-time 30 "
            f"--data-urlencode 'username={identity}' "
            f"--data-urlencode 'password={password}' "
            f"{BASE}/api/auth/token"
        ).strip())

    def token():
        raw = services_vm.succeed(
            "curl -fsS --max-time 30 "
            f"--data-urlencode 'username={ADMIN_EMAIL}' "
            f"--data-urlencode 'password={ADMIN_PASSWORD}' "
            f"{BASE}/api/auth/token"
        )
        return json.loads(raw)["access_token"]

    def sql(q):
        # Read-only query against the LIVE database file, host-side. Retried
        # by callers via wait_until_succeeds where a writer could hold the
        # lock; journal mode is upstream-default rollback (no WAL sidecars).
        return services_vm.succeed(f"sqlite3 'file:{DB}?mode=ro' \"{q}\"").strip()

    start_all()

    with subtest("decrypt-sops-envs produced a 0600 .env owned by uid 1000 (the /srv/stacks world)"):
        services_vm.wait_for_unit("multi-user.target")
        services_vm.wait_for_unit("docker-network-homelab.service")
        # NOT wait_for_unit on decrypt-sops-envs: it is a transient oneshot
        # re-fired by a minutely timer; the artifact is the sync point.
        services_vm.wait_until_succeeds("test -s /srv/stacks/mealie/.env", timeout=120)
        stat = services_vm.succeed("stat -c '%a %u:%g' /srv/stacks/mealie/.env").strip()
        assert stat == "600 1000:1000", f".env is {stat}"
        for k in ["MEALIE_ADMIN_USER", "MEALIE_ADMIN_EMAIL", "MEALIE_ADMIN_PASSWORD"]:
            services_vm.succeed(f"grep -q '^{k}=.' /srv/stacks/mealie/.env")

    services_vm.wait_for_unit("load-test-images.service")

    with subtest("compose up brings the app healthy"):
        try:
            # Start EVERYTHING first, including the one-shot — enumerating
            # services in the --wait call below means only those get created,
            # and the init container would never run at all.
            services_vm.succeed(f"{MEALIE} up -d")
            # No --wait on mealie_init: it must EXIT, and `up --wait` fails on
            # an exited service (finding #39).
            services_vm.succeed(f"{MEALIE} up -d --wait --wait-timeout 900 mealie")
        except Exception:
            diag("compose up failed")
            raise

    with subtest("mealie_init created the real admin and retired the default"):
        services_vm.wait_until_succeeds(
            "docker inspect -f '{{.State.Status}}/{{.State.ExitCode}}' "
            "mealie_init | grep -qx exited/0",
            timeout=600,
        )
        logs = services_vm.succeed("docker logs mealie_init 2>&1")
        assert f"CHANGE: created admin {ADMIN_USER}" in logs, logs
        assert "CHANGE: deleted the default admin" in logs, logs

    with subtest("🚨 the PUBLISHED credential is dead, the real one works"):
        # changeme@example.com / MyPassword is an ADMIN login shipped in the
        # public repository, and v3 removed the env vars that changed it.
        # This pair of assertions is the whole reason mealie_init exists.
        assert login_code(DEFAULT_EMAIL, DEFAULT_PASSWORD) == 401
        assert login_code("admin", DEFAULT_PASSWORD) == 401  # by username too
        assert login_code(ADMIN_EMAIL, ADMIN_PASSWORD) == 200

        # The app's own first-login flag agrees (it keys on a
        # changeme@example.com user EXISTING — verified in app_about.py).
        startup = json.loads(services_vm.succeed(
            f"curl -fsS --max-time 30 {BASE}/api/app/about/startup-info"
        ))
        assert startup["isFirstLogin"] is False, startup

    with subtest("exactly one user remains, and it is the admin"):
        tok = token()
        users = json.loads(services_vm.succeed(
            f"curl -fsS --max-time 30 -H 'Authorization: Bearer {tok}' "
            f"'{BASE}/api/admin/users?perPage=-1'"
        ))["items"]
        assert len(users) == 1, users
        assert users[0]["username"] == ADMIN_USER, users[0]
        assert users[0]["admin"] is True, users[0]

    with subtest("🚨 the database is THE sqlite file on the bind mount"):
        # The anti-phantom assertion, tandoor's pointed the other way: the
        # user the API just returned must be a ROW in /mnt/fast/mealie/
        # mealie.db on the HOST. If Mealie were writing anywhere else — a
        # container-layer file, an unexpected postgres — this file would not
        # hold the account that demonstrably logs in.
        services_vm.wait_until_succeeds(
            f"sqlite3 'file:{DB}?mode=ro' "
            f"\"select count(*) from users where username='{ADMIN_USER}'\" "
            "| grep -qx 1",
            timeout=60,
        )
        assert sql("select count(*) from users where email='changeme@example.com'") == "0"
        # And the engine choice is pinned where .env cannot flip it:
        env = services_vm.succeed(
            "docker inspect --format "
            "'{{range .Config.Env}}{{println .}}{{end}}' mealie"
        )
        assert "DB_ENGINE=sqlite" in env, env
        assert "\nPOSTGRES_" not in "\n" + env, "stray postgres config:\n" + env

    with subtest("token-signing secrets landed in the backed-up data dir"):
        # determine_secrets writes both at first boot; they live on the fast
        # tier WITH the database, so a restore brings back sessions too.
        services_vm.succeed("test -s /mnt/fast/mealie/.secret")
        services_vm.succeed("test -s /mnt/fast/mealie/.session_secret")

    with subtest("signup is closed"):
        about = json.loads(services_vm.succeed(
            f"curl -fsS --max-time 30 {BASE}/api/app/about"
        ))
        assert about["allowSignup"] is False, about

    with subtest("mealie_init is idempotent — a redeploy changes nothing"):
        services_vm.succeed("docker rm -f mealie_init")
        services_vm.succeed(f"{MEALIE} up -d mealie_init")
        services_vm.wait_until_succeeds(
            "docker inspect -f '{{.State.Status}}/{{.State.ExitCode}}' "
            "mealie_init | grep -qx exited/0",
            timeout=300,
        )
        logs = services_vm.succeed("docker logs mealie_init 2>&1")
        assert "CHANGE:" not in logs, f"second run mutated something:\n{logs}"
        assert "default admin already retired" in logs, logs

    with subtest("backup-prepare's sqlite_backup contract holds"):
        # The exact operation backup-prepare.sh performs, against the LIVE
        # writer — `.backup` is the safe path a raw cp is not.
        services_vm.succeed(f"sqlite3 {DB} \".backup '/tmp/mealie.sqlite'\"")
        services_vm.succeed("test -s /tmp/mealie.sqlite")
        out = services_vm.succeed(
            "sqlite3 /tmp/mealie.sqlite 'select count(*) from users'"
        ).strip()
        assert out == "1", f"backup holds {out} users"

    with subtest("10352 is loopback-only, with a positive control"):
        ip = services_vm.succeed(
            "ip -4 -o addr show eth1 | awk '{print $4}' | cut -d/ -f1"
        ).strip()
        outsider.wait_for_unit("network.target")
        outsider.fail(f"curl -s --max-time 10 http://{ip}:10352/api/app/about >/dev/null")
        outsider.succeed(f"ping -c1 -W5 {ip} >/dev/null")

    with subtest("state survives a reboot"):
        services_vm.shutdown()
        services_vm.start()
        services_vm.wait_for_unit("multi-user.target")
        services_vm.wait_until_succeeds("test -s /srv/stacks/mealie/.env", timeout=180)
        services_vm.wait_for_unit("load-test-images.service")
        # Start EVERYTHING first, then --wait on the long-running service
        # only (same shape as above; the init rerun is covered by the
        # idempotence subtest's zero-CHANGE contract).
        services_vm.succeed(f"{MEALIE} up -d")
        services_vm.succeed(f"{MEALIE} up -d --wait --wait-timeout 900 mealie")
        assert login_code(ADMIN_EMAIL, ADMIN_PASSWORD) == 200
        assert login_code(DEFAULT_EMAIL, DEFAULT_PASSWORD) == 401
        services_vm.wait_until_succeeds(
            f"sqlite3 'file:{DB}?mode=ro' "
            f"\"select count(*) from users where username='{ADMIN_USER}'\" "
            "| grep -qx 1",
            timeout=60,
        )
  '';
}
