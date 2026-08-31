# Dawarich suite (heavy): the Rails app, its Sidekiq worker, PostGIS and
# Redis, plus the rails-runner init container. One of THREE stacks in the
# 10300-10349 range (annex §1) — tracking and firefly are separate compose
# projects with their own suites.
#
# Hand-written because mk-stack-suite asserts every container is `running`
# (dawarich_init is a restart:"no" oneshot) and because the two failure modes
# this stack actually has are both INVISIBLE to a generic health assertion.
#
# Genuinely under test:
#   - **The healthcheck/Sidekiq interlock.** APPLICATION_PROTOCOL=https installs
#     ActionDispatch::SSL with force_ssl and there is no ssl_options exclusion
#     anywhere in the repo, so a healthcheck that sends no X-Forwarded-Proto is
#     301'd to https://127.0.0.1:3000 where Puma speaks plain HTTP. The
#     container is then permanently `unhealthy` — and sidekiq declares
#     `condition: service_healthy` on it, so THE WORKER NEVER STARTS. Imports
#     and statistics hang forever with a web UI that looks perfect. The suite
#     asserts the app is healthy AND that Sidekiq has registered a live process
#     in Redis, and separately pins the 301 that makes the header necessary.
#   - **The mirror image: APPLICATION_HOSTS.** config.host_authorization
#     explicitly EXCLUDES /api/v1/health, so a typo'd hostname yields a healthy
#     container, a happy Arcane, a happy Uptime Kuma — and a 403 "Blocked
#     hosts" on every browser request. The suite fetches `/` with the real Host
#     header and, as the control, with a wrong one.
#   - **The seeded admin is GONE.** db/seeds.rb creates
#     demo@dawarich.app / safepassword as an ACTIVE ADMIN, guarded only by
#     `User.none?`, and the entrypoint re-runs `db:seed` on every boot. There
#     is no env var to change it, and POST /api/v1/auth/register creates a
#     NON-admin user so it cannot replace it. dawarich_init renames the account
#     in place via `rails runner`; the suite asserts BOTH that the real admin
#     authenticates AND that the seeded credentials no longer do. The second
#     half is the one that matters.
#   - dawarich_init's idempotency: a second run logs ZERO "CHANGE:" lines,
#     which is what every Arcane redeploy will do.
#   - the backup contract by executing it: `pg_dumpall -U dawarich` inside
#     `dawarich_db`, exactly as nixos/backup-prepare.sh builds it.
#   - the OIDC-ready-but-OFF shipping state.
#   - loopback-only publishing from another host, with a positive control.
#   - reboot durability on a real disk.
#
# Documented gaps (a green run covers NONE of these):
#   - **The OIDC login.** Ships off because the Authentik client secret needs
#     the production age key. What is asserted is the deliberate off-state.
#   - **Reverse geocoding.** Disabled by default (no PHOTON_API_HOST) and
#     self-hosting Photon needs a ~150 GB planet index.
#   - **Any real tracker client.** Overland/OwnTracks/Traccar posting points is
#     the actual data plane and none of it is exercised; what the suite proves
#     is that the API surface those clients use is reachable without a redirect.
#   - **Map tiles.** Client-side, so the container needs no egress — but an
#     air-gapped browser shows a blank map, and nothing here would notice.

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
    images."freikin_dawarich_1_14_0" # app, sidekiq AND dawarich_init
    images."postgis_postgis_17-3_5-alpine"
    images."redis_7_4-alpine"
  ];

  seedSrv = pkgs.runCommand "srv-seed-dawarich" { } ''
    mkdir -p $out/stacks/dawarich
    cp -r ${../../stacks/dawarich}/. $out/stacks/dawarich/
    chmod -R u+w $out/stacks/dawarich
    # The working-tree cp -r can capture a developer's locally-decrypted
    # plaintext .env (gitignored on purpose) in the world-readable store.
    rm -f $out/stacks/dawarich/.env
    rm -f $out/stacks/dawarich/.sops.env.example
    cp ${../fixtures/dawarich.sops.env} $out/stacks/dawarich/.sops.env
  '';
in
pkgs.testers.runNixOSTest {
  name = "dawarich";

  # A PostGIS first boot, Rails migrations, ~250 country multipolygons seeded
  # into PostGIS, and a reboot. The driver's 3600s default would kill the VMs
  # without running any except handler, so the diag dumps would never print.
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

        # Arcane stays out of the boot path (mk-stack-suite's rationale);
        # checks.services covers that chain.
        systemd.services.bootstrap-arcane.wantedBy = lib.mkForce [ ];

        virtualisation.cores = lib.mkForce 4;

        # /srv is tmpfs so its post-reboot re-seed + re-decrypt is the
        # production shape; /mnt is a real ext4 on a persistent qcow because
        # the reboot subtest asserts DATA durability — the user account created
        # by dawarich_init must survive, and so must the country seed.
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
          # 1000:1000 on the app dirs because both entrypoints gosu-drop to
          # PUID/PGID; 999:999 on redis because that image does not chown.
          "d /mnt/fast/dawarich 0755 root root -"
          "d /mnt/fast/dawarich/public 0755 1000 1000 -"
          "d /mnt/fast/dawarich/storage 0755 1000 1000 -"
          "d /mnt/fast/dawarich/watched 0755 1000 1000 -"
          "d /mnt/fast/dawarich/pgdata 0755 root root -"
          "d /mnt/fast/dawarich/redis 0755 999 999 -"
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

        environment.systemPackages = with pkgs; [
          docker-compose
          jq
        ];
      };

    outsider = { };
  };

  testScript = ''
    import json
    import shlex

    DAWARICH = "docker compose -f /srv/stacks/dawarich/compose.yaml -p dawarich"
    BASE = "http://127.0.0.1:10304"
    VHOST = "dawarich.svc.idanreed.com"

    # Fixture values from tests/fixtures/dawarich.sops.env.
    ADMIN = "test-admin@example.invalid"
    ADMIN_PASS = "test_dawarich_admin_password_not_secret"

    # What db/seeds.rb creates, and what must NOT work afterwards. Note the
    # password is `safepassword` — stale guides say `password`, which would
    # make this negative assertion pass against a completely unprovisioned
    # instance.
    SEEDED_ADMIN = "demo@dawarich.app"
    SEEDED_PASS = "safepassword"

    def diag(label):
        print("=== diagnostics: " + label + " ===")
        for cmd in [
            "docker ps -a",
            "docker logs dawarich 2>&1 | tail -80",
            "docker logs dawarich_sidekiq 2>&1 | tail -60",
            "docker logs dawarich_db 2>&1 | tail -30",
            "docker logs dawarich_init 2>&1 | tail -40",
            "docker inspect --format '{{.State.Health.Status}}' dawarich 2>&1",
            "ls -la /mnt/fast/dawarich 2>&1",
            "df -h /var/lib/docker /mnt; free -m",
        ]:
            print("--- " + cmd)
            print(services_vm.execute(cmd)[1])

    def curl(path, method="GET", body=None, headers=None, host=VHOST,
             raw_status=False, follow=False, timeout=60):
        """Every request carries X-Forwarded-Proto: https.

        Without it force_ssl 301s to https://127.0.0.1:3000 and the TLS
        handshake against a plain-HTTP Puma fails — see the no_proto subtest,
        which pins that behaviour deliberately.
        """
        hdrs = {"X-Forwarded-Proto": "https"}
        if host is not None:
            hdrs["Host"] = host
        hdrs.update(headers or {})
        flags = "-s -o /dev/null -w '%{http_code}'" if raw_status else "-sf"
        if not follow:
            flags += " --max-redirs 0"
        cmd = f"curl {flags} --max-time {timeout} -X {method} "
        for k, v in hdrs.items():
            cmd += f"-H {shlex.quote(k + ': ' + v)} "
        if body is not None:
            payload = shlex.quote(json.dumps(body))
            cmd = (f"printf '%s' {payload} | " + cmd
                   + "-H 'Content-Type: application/json' -d @- ")
        out = services_vm.succeed(cmd + shlex.quote(BASE + path))
        if raw_status:
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
    with subtest("decrypt-sops-envs produced a 0600 .env owned by arcane's uid"):
        services_vm.wait_for_unit("multi-user.target")
        services_vm.wait_for_unit("docker-network-homelab.service")
        services_vm.wait_until_succeeds(
            "test -s /srv/stacks/dawarich/.env", timeout=120
        )
        stat = services_vm.succeed(
            "stat -c '%a %u:%g' /srv/stacks/dawarich/.env"
        ).strip()
        assert stat == "600 1000:1000", f".env is {stat}, expected 600 1000:1000"
        for k in ["SECRET_KEY_BASE", "POSTGRES_PASSWORD", "DATABASE_PASSWORD",
                  "DAWARICH_ADMIN_EMAIL", "DAWARICH_ADMIN_PASSWORD"]:
            services_vm.succeed(f"grep -q '^{k}=.' /srv/stacks/dawarich/.env")
        # The OIDC secret is asserted PRESENT AND EMPTY — that is the shipping
        # state this suite pins, not an oversight.
        services_vm.succeed(
            "grep -qx 'DAWARICH_OIDC_CLIENT_SECRET=' /srv/stacks/dawarich/.env"
        )

    services_vm.wait_for_unit("load-test-images.service")

    # -----------------------------------------------------------------------
    # the stack comes up
    # -----------------------------------------------------------------------
    with subtest("compose up brings every container to a healthy state"):
        try:
            # Start EVERYTHING first, including the one-shots — enumerating
            # services in the --wait call below means only those get created,
            # and the init container would never run at all.
            services_vm.succeed(f"{DAWARICH} up -d")
            services_vm.succeed(
                f"{DAWARICH} up -d --wait --wait-timeout 1800 dawarich dawarich_sidekiq dawarich_db dawarich_redis"
            )
        except Exception:
            diag("compose up failed")
            raise

    with subtest("the app reports healthy, which the https trap would prevent"):
        # This is the assertion the whole §6 comment block exists for. If
        # APPLICATION_PROTOCOL=https were set without the healthcheck carrying
        # X-Forwarded-Proto, the container would sit `unhealthy` forever and
        # the --wait above would already have failed — but assert it directly
        # so the reason is legible in the log rather than inferred from a
        # timeout.
        health = services_vm.succeed(
            "docker inspect --format '{{.State.Health.Status}}' dawarich"
        ).strip()
        assert health == "healthy", f"dawarich health is {health}"

    with subtest("no X-Forwarded-Proto really does 301 — the trap, pinned"):
        # Not a bug being tolerated: this is the behaviour that makes the
        # healthcheck's header load-bearing. If a future version stops doing
        # this, the header becomes dead config and this subtest says so.
        code = int(services_vm.succeed(
            "curl -s -o /dev/null -w '%{http_code}' --max-redirs 0 "
            f"--max-time 30 -H 'Host: {VHOST}' {BASE}/"
        ).strip())
        assert code == 301, (
            f"expected a 301 from force_ssl without X-Forwarded-Proto, got {code}. "
            "If this is now 200, ActionDispatch::SSL is no longer installed and "
            "the healthcheck's --header flag is dead config."
        )

    # -----------------------------------------------------------------------
    # APPLICATION_HOSTS — the failure the healthcheck cannot see
    # -----------------------------------------------------------------------
    with subtest("the real vhost is accepted by host authorization"):
        code = curl("/", raw_status=True)
        # 200 (login page) or 302 to /users/sign_in are both fine; 403 is the
        # failure this exists to catch.
        assert code in (200, 302), f"GET / with Host: {VHOST} returned {code}"

    with subtest("a wrong Host is REJECTED — the control for the above"):
        # Without this control the previous subtest would pass even if host
        # authorization were disabled entirely, which is precisely the state a
        # future `config.hosts.clear()` would produce.
        code = curl("/", host="wrong.invalid", raw_status=True)
        assert code == 403, (
            f"GET / with a bogus Host returned {code}, expected 403. "
            "Host authorization is not actually filtering anything, so a typo "
            "in APPLICATION_HOSTS would go unnoticed."
        )

    with subtest("/api/v1/health is EXCLUDED from host authorization"):
        # Pinning the asymmetry itself: this is why a Caddy smoke test must
        # never use the health endpoint.
        code = curl("/api/v1/health", host="wrong.invalid", raw_status=True)
        assert code == 200, (
            f"/api/v1/health with a bogus Host returned {code}, expected 200 — "
            "the exclusion documented in §6 no longer holds, so the health "
            "endpoint may now be a valid hostname check after all."
        )

    # -----------------------------------------------------------------------
    # Sidekiq is really running
    # -----------------------------------------------------------------------
    with subtest("Sidekiq registered a live process in Redis"):
        # `pgrep -f sidekiq` (the compose healthcheck) proves a process exists;
        # it does not prove the worker connected to Redis and can pick up work.
        # Sidekiq writes a heartbeat into the `processes` set every 5s, so a
        # non-empty set is the real liveness signal. RAILS_JOB_QUEUE_DB is 1,
        # but both databases are checked so a future default change surfaces as
        # a passing test with a different db number rather than a failure.
        # RETRIED, not sampled once. sidekiq's container healthcheck is
        # `pgrep -f sidekiq`, which passes the moment the process exists —
        # before it has connected to Redis and written its first heartbeat. So
        # `up --wait` returning says nothing about whether the worker is
        # registered yet, and a single check here raced it.
        services_vm.wait_until_succeeds(
            "docker exec dawarich_redis sh -c "
            "'redis-cli -n 0 SMEMBERS processes; redis-cli -n 1 SMEMBERS processes' "
            "| grep -q .",
            timeout=240,
        )
        found = []
        for db in (0, 1):
            out = services_vm.succeed(
                f"docker exec dawarich_redis redis-cli -n {db} SMEMBERS processes"
            ).strip()
            if out:
                found.append((db, out))
        assert found, (
            "no Sidekiq process heartbeat in Redis db 0 or 1 — the worker is "
            "not connected, which is exactly the state the force_ssl interlock "
            "produces while the web UI looks perfect."
        )
        print("sidekiq processes:", found)

    # -----------------------------------------------------------------------
    # the seeded admin, and the real one
    # -----------------------------------------------------------------------
    with subtest("dawarich_init exited 0 and reported its change"):
        services_vm.wait_until_succeeds(
            "docker inspect --format '{{.State.Status}}' dawarich_init "
            "| grep -qx exited",
            timeout=600,
        )
        rc = services_vm.succeed(
            "docker inspect --format '{{.State.ExitCode}}' dawarich_init"
        ).strip()
        assert rc == "0", f"dawarich_init exited {rc}"
        logs = services_vm.succeed("docker logs dawarich_init 2>&1")
        assert "CHANGE: renamed the seeded" in logs, logs
        assert "done" in logs, logs

    with subtest("the REAL admin authenticates"):
        out = curl("/api/v1/auth/login", method="POST",
                   body={"email": ADMIN, "password": ADMIN_PASS})
        assert isinstance(out, dict), out
        assert out.get("api_key"), f"login returned no api_key: {out}"

    with subtest("the SEEDED admin no longer authenticates — the one that matters"):
        # A dawarich_init that silently did nothing would leave
        # demo@dawarich.app / safepassword — a published-password ADMIN — on a
        # database holding every location this instance has recorded. Every
        # other assertion in this suite would still pass.
        code = curl("/api/v1/auth/login", method="POST",
                    body={"email": SEEDED_ADMIN, "password": SEEDED_PASS},
                    raw_status=True)
        assert code == 401, (
            f"login as {SEEDED_ADMIN}/{SEEDED_PASS} returned {code}, expected 401"
        )

    with subtest("dawarich_init is idempotent — a redeploy changes nothing"):
        # Every Arcane redeploy reruns this container.
        services_vm.succeed("docker rm -f dawarich_init")
        services_vm.succeed(f"{DAWARICH} up -d dawarich_init")
        services_vm.wait_until_succeeds(
            "docker inspect --format '{{.State.Status}}' dawarich_init "
            "| grep -qx exited",
            timeout=300,
        )
        rc = services_vm.succeed(
            "docker inspect --format '{{.State.ExitCode}}' dawarich_init"
        ).strip()
        assert rc == "0", f"second dawarich_init run exited {rc}"
        logs = services_vm.succeed("docker logs dawarich_init 2>&1")
        assert "CHANGE:" not in logs, f"second run mutated something:\n{logs}"
        assert "already exists" in logs, logs

    # -----------------------------------------------------------------------
    # backup contract, executed rather than asserted about
    # -----------------------------------------------------------------------
    with subtest("backup-prepare's pg_dumpall contract holds"):
        # Exactly how nixos/backup-prepare.sh builds it: container "<svc>_db",
        # `pg_dumpall -U <svc>`. Both halves are in stacks/dawarich/compose.yaml
        # and neither matches what upstream ships, so this is the assertion that
        # keeps a future "normalise the names" edit from silently emptying the
        # backup.
        # Redirected to a file rather than piped to `head`: pg_dumpall keeps
        # writing after head closes the pipe, so the pipeline exits 141
        # (SIGPIPE) and `succeed` treats a perfectly good dump as a failure.
        services_vm.succeed(
            "docker exec dawarich_db pg_dumpall -U dawarich > /tmp/dawarich.sql"
        )
        out = services_vm.succeed("head -40 /tmp/dawarich.sql")
        assert "CREATE ROLE" in out or "ROLE dawarich" in out, out

    with subtest("the PostGIS extension is actually installed"):
        # config/database.yml declares `adapter: postgis`; a plain postgres
        # image would have failed at connect time, but an image WITH postgis
        # binaries and WITHOUT the extension enabled in this database fails
        # later and less obviously.
        out = services_vm.succeed(
            "docker exec dawarich_db psql -U dawarich -d dawarich -tAc "
            "\"select extname from pg_extension where extname='postgis'\""
        ).strip()
        assert out == "postgis", f"postgis extension not present: {out!r}"

    # -----------------------------------------------------------------------
    # publishing
    # -----------------------------------------------------------------------
    with subtest("10304 is loopback-only, with a positive control"):
        ip = services_vm.succeed(
            "ip -4 -o addr show eth1 | awk '{print $4}' | cut -d/ -f1"
        ).strip()
        outsider.wait_for_unit("network.target")
        outsider.fail(f"curl -s --max-time 10 http://{ip}:10304/ >/dev/null")
        # Positive control: the outsider can reach the VM at all, so the
        # failure above is the binding and not a dead network.
        outsider.succeed(f"ping -c1 -W5 {ip} >/dev/null")

    # -----------------------------------------------------------------------
    # durability
    # -----------------------------------------------------------------------
    with subtest("state survives a reboot"):
        # shutdown()+start(), not reboot(): the driver runs qemu with
        # -no-reboot, so reboot() kills the VM.
        services_vm.shutdown()
        services_vm.start()
        services_vm.wait_for_unit("multi-user.target")
        services_vm.wait_until_succeeds(
            "test -s /srv/stacks/dawarich/.env", timeout=180
        )
        services_vm.wait_for_unit("load-test-images.service")
        # Start EVERYTHING first, including the one-shots — enumerating
        # services in the --wait call below means only those get created,
        # and the init container would never run at all.
        services_vm.succeed(f"{DAWARICH} up -d")
        services_vm.succeed(
            f"{DAWARICH} up -d --wait --wait-timeout 1800 dawarich dawarich_sidekiq dawarich_db dawarich_redis"
        )

        # The account survived, and — critically — db:seed did NOT recreate the
        # demo user, because `User.none?` is false now.
        out = curl("/api/v1/auth/login", method="POST",
                   body={"email": ADMIN, "password": ADMIN_PASS})
        assert isinstance(out, dict) and out.get("api_key"), out
        code = curl("/api/v1/auth/login", method="POST",
                    body={"email": SEEDED_ADMIN, "password": SEEDED_PASS},
                    raw_status=True)
        assert code == 401, (
            f"after reboot, {SEEDED_ADMIN} authenticates again ({code}) — "
            "db:seed reseeded it, which means the User.none? guard no longer "
            "holds and the account is recreated on every boot."
        )
  '';
}
