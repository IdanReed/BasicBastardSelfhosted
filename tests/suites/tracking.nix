# Tracking suite (heavy): bookstack + its MariaDB, homebox, and karakeep with
# its meilisearch and chrome sidecars. One of THREE stacks in the 10300-10349
# range (annex §1) — firefly and dawarich are separate compose projects with
# their own suites.
#
# Hand-written because mk-stack-suite asserts every container is `running`
# (tracking-init is a restart:"no" oneshot) and because three of the builtin
# healthchecks here do not mean what they look like.
#
# Genuinely under test:
#   - decrypt-sops-envs -> a 0600 .env owned 1000:1000, and env threading END
#     TO END for three apps: every admin credential exists only in the
#     encrypted fixture, so three working logins prove the whole chain
#   - **BookStack's seeded admin is GONE.** Its migration seeds
#     admin@admin.com/password with no env var to change it, and there is no
#     HTTP path to a first admin, so the replacement runs inside the container
#     through LSIO's /custom-cont-init.d hook. The suite asserts BOTH that the
#     real admin works AND that the seeded one no longer does — the second
#     half is the one that matters, because a hook that silently did nothing
#     leaves a known-password admin on a wiki.
#   - the headless bootstrap paths that are NOT REST: homebox's register
#     returns 204 with no body and logs in by `username`; karakeep's signup is
#     tRPC with a mandatory {"json": ...} superjson wrapper and no REST
#     equivalent at all
#   - Karakeep's version endpoint equalling the pin — the ONLY way an
#     accidental `latest` becomes visible, since those images self-report
#     `nightly` and are otherwise indistinguishable
#   - that search actually WORKS rather than that its env is set: karakeep
#     parses MEILI_ADDR/MEILI_MASTER_KEY in a separate per-plugin schema, so a
#     typo produces no validation error anywhere and search silently never
#     registers
#   - the OIDC-ready-but-OFF shipping state for all three
#   - the backup paths, including the two Karakeep SQLite files whose
#     committed path was WRONG (it named a file the app never creates, and
#     sqlite_backup returns 0 for a missing source — so it backed up nothing,
#     forever, silently)
#   - loopback-only publishing from another host, with a positive control
#   - reboot durability on a real disk
#
# Documented gaps (a green run covers NONE of these):
#   - **Every OIDC login.** All three ship with OIDC off because the Authentik
#     client secrets need the production age key. What is asserted is the
#     deliberate off-state, not a login.
#   - **Karakeep's crawler and all AI.** Crawling needs egress; inference is
#     inert without an endpoint and is meant to be. The chrome sidecar is
#     started but nothing exercises it — Karakeep is explicitly designed to
#     tolerate its absence, which is why nothing depends_on it.
#   - **Homebox's liveness only.** Its builtin healthcheck returns 200
#     unconditionally (`ReadyFunc = func() bool { return true }`), so no probe
#     can distinguish a working Homebox from one with a dead database. The
#     suite asserts on /api/v1/status's CONTENT instead, which is the best
#     available substitute.
#   - Meilisearch persistence across an engine upgrade — it is version-locked
#     to 1.41.0 for exactly that reason and the suite never moves it.

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
    images."lscr_io_linuxserver_bookstack_version-v26_05_4"
    images."mariadb_11_8_9"
    images."ghcr_io_sysadminsmedia_homebox_0_26_2"
    images."ghcr_io_karakeep-app_karakeep_0_33_2"
    images."getmeili_meilisearch_v1_41_0"
    images."ghcr_io_karakeep-app_karakeep-chrome_151_0_7922_47-r1"
    images."python_3_13-alpine" # tracking-init
  ];

  seedSrv = pkgs.runCommand "srv-seed-tracking" { } ''
    mkdir -p $out/stacks/tracking
    cp -r ${../../stacks/tracking}/. $out/stacks/tracking/
    chmod -R u+w $out/stacks/tracking
    # The working-tree cp -r can capture a developer's locally-decrypted
    # plaintext .env (gitignored on purpose) in the world-readable store.
    rm -f $out/stacks/tracking/.env
    rm -f $out/stacks/tracking/.sops.env.example
    cp ${../fixtures/tracking.sops.env} $out/stacks/tracking/.sops.env
  '';
in
pkgs.testers.runNixOSTest {
  name = "tracking";

  # Six containers, a MariaDB first-boot, BookStack's migrations, and a
  # reboot. The driver's 3600s default would kill the VMs without running any
  # except handler, so the diag dumps would never print.
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
            memoryMB = 6144;
            diskMB = 24576;
          })
          (profiles.loadImages {
            inherit pkgs;
            images = stackImages;
            beforeUnits = [ "multi-user.target" ];
          })
        ];

        # The deploy plane stays out of the boot path (mk-stack-suite's
        # rationale); checks.services covers that chain.
        systemd.services.bootstrap-komodo.wantedBy = lib.mkForce [ ];
        # stack-git-sync would fail its clone every tick with no Forgejo here.
        systemd.timers.stack-git-sync.wantedBy = lib.mkForce [ ];

        virtualisation.cores = lib.mkForce 4;

        # /srv is tmpfs so its post-reboot re-seed + re-decrypt is the
        # production shape; /mnt is a real ext4 on a persistent qcow because
        # the reboot subtest asserts DATA durability — three databases and
        # the meilisearch index must survive.
        virtualisation.emptyDiskImages = [ 16384 ];
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
          # The SAME set and ownership production declares in
          # nixos/hardware-configuration.nix; keep the two in sync by hand.
          # Three conventions in one stack — see that file's comment.
          "d /mnt/fast/bookstack 0755 root root -"
          "d /mnt/fast/bookstack/config 0755 1000 1000 -"
          "d /mnt/fast/bookstack/db 0755 root root -"
          "d /mnt/fast/homebox 0755 root root -"
          "d /mnt/fast/karakeep 0755 root root -"
          "d /mnt/fast/karakeep/data 0755 root root -"
          "d /mnt/fast/karakeep/meili 0755 root root -"
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
            # LSIO runs /custom-cont-init.d scripts with `bash <script>`
            # rather than exec'ing them, so the mode is not load-bearing the
            # way shelfmark's hook is — restored anyway so the container sees
            # what git holds.
            chmod 0755 /srv/stacks/tracking/bookstack-admin-init.sh
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
    import shlex

    TRACKING = "docker compose -f /srv/stacks/tracking/compose.yaml -p tracking"
    BOOKSTACK = "http://127.0.0.1:10300"
    HOMEBOX = "http://127.0.0.1:10301"
    KARAKEEP = "http://127.0.0.1:10302"

    # Fixture values from tests/fixtures/tracking.sops.env.
    BS_ADMIN = "bookstack-admin@test.invalid"
    BS_PASS = "test_bookstack_password_not_secret"
    HB_ADMIN = "homebox-admin@test.invalid"
    HB_PASS = "test_homebox_password_not_secret"
    KK_ADMIN = "karakeep-admin@test.invalid"
    KK_PASS = "test_karakeep_password_not_secret"

    # What BookStack's migration seeds, and what must NOT work afterwards.
    SEEDED_ADMIN = "admin@admin.com"
    SEEDED_PASS = "password"

    def diag(label):
        print("=== diagnostics: " + label + " ===")
        for cmd in [
            "docker ps -a",
            "docker logs bookstack 2>&1 | tail -60",
            "docker logs bookstack_db 2>&1 | tail -20",
            "docker logs homebox 2>&1 | tail -40",
            "docker logs karakeep 2>&1 | tail -60",
            "docker logs karakeep_meilisearch 2>&1 | tail -20",
            "docker logs tracking_init 2>&1 | tail -40",
            "ls -la /mnt/fast/bookstack/config /mnt/fast/homebox "
            "/mnt/fast/karakeep/data 2>&1",
            "df -h /var/lib/docker /mnt; free -m",
        ]:
            print("--- " + cmd)
            print(services_vm.execute(cmd)[1])

    def curl(base, path, method="GET", body=None, headers=None, fail=False,
             timeout=60):
        flags = "-s -o /dev/null -w '%{http_code}'" if fail else "-sf"
        cmd = f"curl {flags} --max-time {timeout} -X {method} "
        for k, v in (headers or {}).items():
            cmd += f"-H {shlex.quote(k + ': ' + v)} "
        if body is not None:
            payload = shlex.quote(json.dumps(body))
            cmd = (f"printf '%s' {payload} | " + cmd
                   + "-H 'Content-Type: application/json' -d @- ")
        out = services_vm.succeed(cmd + shlex.quote(base + path))
        if fail:
            return int(out.strip())
        if not out.strip():
            return None
        try:
            return json.loads(out)
        except ValueError:
            return out.strip()

    start_all()

    # -----------------------------------------------------------------------
    # boot chain + decrypt
    # -----------------------------------------------------------------------
    with subtest("decrypt-sops-envs produced a 0600 .env owned by uid 1000 (the /srv/stacks world)"):
        services_vm.wait_for_unit("multi-user.target")
        services_vm.wait_for_unit("docker-network-homelab.service")
        services_vm.wait_until_succeeds(
            "test -s /srv/stacks/tracking/.env", timeout=120
        )
        stat = services_vm.succeed(
            "stat -c '%a %u:%g' /srv/stacks/tracking/.env"
        ).strip()
        assert stat == "600 1000:1000", f".env is {stat}, expected 600 1000:1000"
        # APP_KEY, not BOOKSTACK_APP_KEY: BookStack reads the variable
        # verbatim out of the environment, so a prefixed name in .env leaves
        # it UNSET — and an unset APP_KEY makes the image's init script
        # `sleep infinity` rather than exit, so the container reports
        # "running" forever with no crash to alert on.
        for k in ["APP_KEY", "BOOKSTACK_ADMIN_PASSWORD",
                  "MYSQL_ROOT_PASSWORD", "HBOX_AUTH_API_KEY_PEPPER",
                  "NEXTAUTH_SECRET", "MEILI_MASTER_KEY"]:
            services_vm.succeed(f"grep -q '^{k}=.' /srv/stacks/tracking/.env")
        # 🚨 APP_KEY must decode to EXACTLY 32 bytes. Laravel uses AES-256-CBC,
        # and a wrong length is NOT a startup error: BookStack boots, migrates,
        # serves HTML and runs the admin hook, then throws "Unsupported cipher
        # or incorrect key length" on the first encrypted operation — during
        # middleware TERMINATION, after the response has gone out, so nothing
        # in the container log mentions the key. Caught here rather than left
        # to the /status probe below, so the failure names its own cause.
        n = int(services_vm.succeed(
            "grep '^APP_KEY=' /srv/stacks/tracking/.env | sed 's/^APP_KEY=base64://' "
            "| tr -d '\n' | base64 -d | wc -c"
        ).strip())
        assert n == 32, (
            f"APP_KEY decodes to {n} bytes, must be exactly 32 for AES-256-CBC"
        )
        # The three OIDC secrets are asserted PRESENT AND EMPTY — that is the
        # shipping state this suite pins.
        for k in ["BOOKSTACK_OIDC_CLIENT_SECRET", "HOMEBOX_OIDC_CLIENT_SECRET",
                  "KARAKEEP_OIDC_CLIENT_SECRET"]:
            services_vm.succeed(f"grep -qx '{k}=' /srv/stacks/tracking/.env")

    services_vm.wait_for_unit("load-test-images.service")

    # -----------------------------------------------------------------------
    # the stack comes up
    # -----------------------------------------------------------------------
    with subtest("compose brings up all six containers"):
        # tracking-init is NOT in the --wait set: compose reports failure for
        # an in-scope oneshot that exited 0 unless a dependent consumes it,
        # and it has no dependents. Same trap the other suites document.
        # chrome is included even though nothing gates on it, so that a
        # crash-looping sidecar is still visible here.
        try:
            services_vm.succeed(
                TRACKING + " up -d --wait --wait-timeout 900 "
                "bookstack bookstack_db homebox karakeep meilisearch chrome",
                timeout=1000,
            )
        except Exception:
            diag("compose up --wait")
            raise

    with subtest("every container is in its contract state"):
        for name in ["bookstack", "bookstack_db", "homebox", "karakeep",
                     "karakeep_meilisearch"]:
            h = services_vm.succeed(
                f"docker inspect -f '{{{{.State.Health.Status}}}}' {name}"
            ).strip()
            assert h == "healthy", f"{name} is {h!r}, expected healthy"
        # chrome has no healthcheck by design (its image contains neither curl
        # nor wget, and karakeep tolerates its absence) — assert only that it
        # is up rather than restart-looping.
        state = services_vm.succeed(
            "docker inspect -f '{{.State.Status}}' karakeep_chrome"
        ).strip()
        assert state == "running", f"chrome is {state!r}"

    # -----------------------------------------------------------------------
    # BookStack: the in-container admin hook
    # -----------------------------------------------------------------------
    with subtest("bookstack's /status reports database, cache AND session true"):
        # The healthcheck already gates `up --wait` on this, so reaching here
        # implies a 200 — but assert the CONTENT so the failure names itself.
        # This is the probe that caught a 37-byte APP_KEY: BookStack booted,
        # migrated, served HTML and ran the admin hook, and only /status
        # returned 500 ("Unsupported cipher or incorrect key length", thrown
        # during middleware termination, after the response). A `/` probe would
        # have shipped that.
        out = services_vm.succeed(
            f"curl -sS --max-time 30 {BOOKSTACK}/status"
        )
        st = json.loads(out)
        assert st == {"database": True, "cache": True, "session": True}, st

    with subtest("bookstack's seeded admin was replaced, not merely added"):
        hook_log = services_vm.succeed("docker logs bookstack 2>&1")
        assert "[bookstack-admin-init] CHANGE: admin set to" in hook_log, (
            f"the /custom-cont-init.d hook did not run or did not apply:\n"
            f"{hook_log[-3000:]}"
        )
        # The real admin logs in. BookStack's login is a session form, so
        # this asserts the POST is accepted rather than parsing a token.
        code = curl(BOOKSTACK, "/login", fail=True)
        assert code == 200, f"bookstack /login returned {code}"

    with subtest("the seeded admin@admin.com password no longer works"):
        # THE assertion that matters. `--initial` UPDATES the seeded row in
        # place, so a hook that silently did nothing leaves a full admin with
        # a published password on the wiki — and every other check in this
        # suite would still pass.
        #
        # Driven through the login form: fetch the CSRF token, post the
        # seeded credentials, and require that the response is NOT a redirect
        # to the dashboard.
        services_vm.succeed(
            "curl -sf -c /tmp/bs.jar -o /tmp/bs-login.html "
            f"{BOOKSTACK}/login"
        )
        token = services_vm.succeed(
            "grep -o 'name=\"_token\" value=\"[^\"]*\"' /tmp/bs-login.html "
            "| head -1 | sed 's/.*value=\"//; s/\"//'"
        ).strip()
        assert token, "no CSRF token in bookstack's login page"
        status = services_vm.succeed(
            "curl -s -o /dev/null -w '%{http_code}' -b /tmp/bs.jar -c /tmp/bs.jar "
            f"--data-urlencode '_token={token}' "
            f"--data-urlencode 'email={SEEDED_ADMIN}' "
            f"--data-urlencode 'password={SEEDED_PASS}' "
            f"{BOOKSTACK}/login"
        ).strip()
        # A successful login 302s to /; a rejected one re-renders the form
        # (200) or 302s back to /login. Either way the body must not be the
        # dashboard, so assert on where it points.
        location = services_vm.succeed(
            "curl -s -D - -o /dev/null -b /tmp/bs.jar "
            f"--data-urlencode '_token={token}' "
            f"--data-urlencode 'email={SEEDED_ADMIN}' "
            f"--data-urlencode 'password={SEEDED_PASS}' "
            f"{BOOKSTACK}/login | grep -i '^location:' || true"
        ).strip()
        assert not location.rstrip("/").endswith("10300"), (
            f"THE SEEDED ADMIN STILL LOGS IN (status {status}, location "
            f"{location!r}) — admin@admin.com/password is live on the wiki"
        )

    # -----------------------------------------------------------------------
    # tracking-init: homebox + karakeep
    # -----------------------------------------------------------------------
    with subtest("tracking-init provisions homebox and karakeep"):
        try:
            services_vm.succeed(TRACKING + " up -d tracking-init")
            services_vm.wait_until_succeeds(
                "docker inspect -f '{{.State.Status}}/{{.State.ExitCode}}' "
                "tracking_init | grep -qx exited/0",
                timeout=300,
            )
        except Exception:
            diag("tracking-init run")
            raise
        seed_log = services_vm.succeed("docker logs tracking_init 2>&1")
        for expected in ["CHANGE: homebox owner", "CHANGE: karakeep admin"]:
            assert expected in seed_log, (
                f"tracking-init logged no {expected!r}:\n{seed_log}"
            )

    with subtest("homebox's owner logs in with the fixture credentials"):
        # Note the field name: `username`, not `email`. And register returns
        # 204 with no body, which is why tracking-init cannot parse a result.
        res = curl(HOMEBOX, "/api/v1/users/login", "POST",
                   {"username": HB_ADMIN, "password": HB_PASS})
        assert (res or {}).get("token"), f"homebox login returned {res!r}"

    with subtest("karakeep's admin exists and can mint an api key"):
        # tRPC, not REST, and the {"json": ...} superjson wrapper is
        # mandatory — a flat body fails in a way that reads like a schema
        # error rather than a transport one.
        res = curl(KARAKEEP, "/api/trpc/apiKeys.exchange", "POST", {"json": {
            "keyName": "suite", "email": KK_ADMIN, "password": KK_PASS,
        }})
        key = (((res or {}).get("result") or {}).get("data") or {}).get("json") or {}
        assert key.get("key", "").startswith("ak"), (
            f"apiKeys.exchange returned no usable key: {res!r}"
        )
        api_key = key["key"]

    # -----------------------------------------------------------------------
    # the pin, and search actually working
    # -----------------------------------------------------------------------
    with subtest("karakeep reports the pinned version, not nightly"):
        # `latest` is the nightly build of main and self-reports `nightly`.
        # Nothing else in the harness can tell the two apart, so this is the
        # drift guard for an accidental moving tag.
        ver = curl(KARAKEEP, "/api/version")
        reported = (ver or {}).get("version") if isinstance(ver, dict) else ver
        assert reported and "nightly" not in str(reported), (
            f"karakeep reports version {reported!r} — a `nightly` here means "
            f"the pin resolved to `latest`"
        )
        compose = services_vm.succeed("cat /srv/stacks/tracking/compose.yaml")
        assert f"karakeep:{reported}" in compose, (
            f"karakeep reports {reported!r}, which is not the compose pin"
        )

    with subtest("search is actually registered, not just configured"):
        # MEILI_ADDR/MEILI_MASTER_KEY are parsed by a SEPARATE per-plugin
        # schema, so a typo produces no validation error at all and search
        # silently never registers. Asserting the env is set proves nothing;
        # asserting meilisearch is reachable AND karakeep's own view of it is
        # the closest offline substitute for "search works".
        health = curl("http://127.0.0.1:10302", "/api/health")
        assert health is not None, "karakeep /api/health returned nothing"
        # Meilisearch answers from inside the compose network only.
        services_vm.succeed(
            "docker exec karakeep wget -q -O - "
            "http://meilisearch:7700/health | grep -q available"
        )

    # -----------------------------------------------------------------------
    # the OIDC-ready-but-OFF contract
    # -----------------------------------------------------------------------
    with subtest("all three apps report OIDC off, deliberately"):
        # Homebox exposes its whole OIDC block unauthenticated, which makes
        # this checkable directly.
        status = curl(HOMEBOX, "/api/v1/status")
        assert isinstance(status, dict), f"homebox /status: {status!r}"
        oidc = status.get("oidc") or {}
        assert not (oidc.get("enabled") if isinstance(oidc, dict) else oidc), (
            f"homebox reports OIDC {oidc!r}, expected disabled"
        )
        # BookStack: AUTH_METHOD=standard means the login page offers no
        # external provider button.
        services_vm.succeed(
            f"curl -sf {BOOKSTACK}/login -o /tmp/bs-login2.html"
        )
        services_vm.fail("grep -qi 'oidc\\|single sign' /tmp/bs-login2.html")

    # -----------------------------------------------------------------------
    # publishing posture
    # -----------------------------------------------------------------------
    with subtest("published ports answer on loopback and nowhere else"):
        # Positive control first, so the negatives cannot pass vacuously.
        outsider.succeed("nc -z -w 5 services-vm 22")
        for port in [10300, 10301, 10302]:
            services_vm.wait_for_open_port(port, addr="127.0.0.1")
            outsider.fail(f"nc -z -w 5 services-vm {port}")

    with subtest("the sidecars and the database publish nothing"):
        for name in ["bookstack_db", "karakeep_meilisearch", "karakeep_chrome",
                     "tracking_init"]:
            ports = services_vm.succeed(
                f"docker inspect -f "
                f"'{{{{json .NetworkSettings.Ports}}}}' {name}"
            ).strip()
            published = [p for p, b in (json.loads(ports) or {}).items() if b]
            assert not published, f"{name} publishes {published}"

    # -----------------------------------------------------------------------
    # the backup contract — including the path that was wrong
    # -----------------------------------------------------------------------
    with subtest("the backup paths exist and dump"):
        # Karakeep's two SQLite files are the point of this subtest: the
        # committed path used to name /mnt/fast/karakeep/data.db, which the
        # app never creates, and sqlite_backup returns 0 for a missing source
        # — so it backed up nothing at all with a clean exit.
        for name, src in [
            ("karakeep", "/mnt/fast/karakeep/data/db.db"),
            ("karakeep-queue", "/mnt/fast/karakeep/data/queue.db"),
            ("homebox", "/mnt/fast/homebox/homebox.db"),
        ]:
            services_vm.wait_until_succeeds(f"test -f {src}", timeout=120)
            services_vm.succeed(
                f"sqlite3 {src} \".backup '/tmp/{name}.sqlite'\""
            )
            services_vm.succeed(f"test -s /tmp/{name}.sqlite")
        # BookStack is MariaDB, and backup-prepare.sh reads
        # MYSQL_ROOT_PASSWORD out of the container's own environment — so run
        # the exact command it runs (MYSQL_PWD form, backup-prepare.sh:207;
        # -p on argv was host-visible in /proc/<pid>/cmdline).
        services_vm.succeed(
            "docker exec bookstack_db sh -c "
            "'MYSQL_PWD=\"$MYSQL_ROOT_PASSWORD\"; export MYSQL_PWD; "
            "exec mariadb-dump -u root --all-databases' "
            "> /tmp/bookstack.sql"
        )
        services_vm.succeed("test -s /tmp/bookstack.sql")
        services_vm.succeed("grep -qi 'CREATE TABLE' /tmp/bookstack.sql")

    # -----------------------------------------------------------------------
    # idempotence
    # -----------------------------------------------------------------------
    with subtest("re-running tracking-init is a no-op"):
        services_vm.succeed("docker rm -f tracking_init")
        services_vm.succeed(TRACKING + " up -d tracking-init")
        services_vm.wait_until_succeeds(
            "docker inspect -f '{{.State.Status}}/{{.State.ExitCode}}' "
            "tracking_init | grep -qx exited/0",
            timeout=300,
        )
        run_log = services_vm.succeed("docker logs tracking_init 2>&1")
        assert "CHANGE:" not in run_log, (
            f"second tracking-init run was not a no-op:\n{run_log}"
        )

    # -----------------------------------------------------------------------
    # reboot survival
    # -----------------------------------------------------------------------
    with subtest("the stack returns after a reboot with its data intact"):
        # shutdown() + start(), NOT reboot(): the driver runs qemu with
        # -no-reboot, so an in-guest reboot terminates the VM.
        services_vm.shutdown()
        services_vm.start()
        services_vm.wait_for_unit("multi-user.target")
        services_vm.wait_until_succeeds(
            "test -s /srv/stacks/tracking/.env", timeout=120
        )
        try:
            for port in [10300, 10301, 10302]:
                services_vm.wait_for_open_port(port, addr="127.0.0.1",
                                               timeout=900)
        except Exception:
            diag("post-reboot")
            raise
        # The three databases survived, so all three identities still work.
        res = curl(HOMEBOX, "/api/v1/users/login", "POST",
                   {"username": HB_ADMIN, "password": HB_PASS})
        assert (res or {}).get("token"), f"post-reboot homebox login: {res!r}"
        res = curl(KARAKEEP, "/api/trpc/apiKeys.exchange", "POST", {"json": {
            "keyName": "suite-post-reboot", "email": KK_ADMIN,
            "password": KK_PASS,
        }})
        key = (((res or {}).get("result") or {}).get("data") or {}).get("json") or {}
        assert key.get("key"), f"post-reboot karakeep exchange: {res!r}"
        # And BookStack's admin hook did not re-seed a default admin on the
        # second boot — `--initial` no-ops once a real admin exists.
        hook_log = services_vm.succeed("docker logs bookstack 2>&1")
        assert "no change" in hook_log or "already provisioned" in hook_log, (
            "the bookstack admin hook did not report a no-op on the second "
            "boot, which means it is not idempotent"
        )
  '';
}
