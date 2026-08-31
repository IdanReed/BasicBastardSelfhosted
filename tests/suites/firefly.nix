# Firefly III suite (heavy): the core app, its Postgres, and the data
# importer. One of THREE stacks in the 10300-10349 range (annex §1) —
# tracking and dawarich are separate compose projects with their own suites.
#
# Hand-written because this is the only stack in the fleet whose
# AUTHENTICATION IS ENTIRELY OUTSIDE ITSELF, and the things worth asserting
# are all about that.
#
# Genuinely under test:
#   - **The remote_user_guard header spelling.** RemoteUserGuard reads
#     `request()->server($header)`, i.e. the raw $_SERVER bag, and the default
#     `REMOTE_USER` CAN NEVER MATCH because the image's nginx never sets it.
#     An inbound HTTP header arrives CGI-mangled, so it must be spelled
#     HTTP_X_AUTHENTIK_EMAIL. The suite drives a request with the header and
#     checks the DATABASE for the account it created — the only unambiguous
#     proof, since Firefly's API uses a different guard entirely.
#   - **That the guard validates NOTHING.** A second, arbitrary header value
#     creates a second account. That is not a bug being tolerated: it is the
#     property that makes the loopback-only publish and the Caddy
#     `import protected` handle load-bearing rather than defence in depth, and
#     pinning it here means a future change to that behaviour is noticed.
#   - **That the builtin healthcheck's default is a lie, and that the fix
#     took.** The image probes `$HEALTHCHECK_PATH`, defaulting to
#     /healthcheck — which nginx routes to php-fpm's own ping.path/ping.response
#     before Laravel is ever invoked. The suite stops the database and asserts
#     that /healthcheck STILL returns 200 while /health does not and the
#     container goes unhealthy. Without that pair, "healthy" here would mean
#     "php-fpm is alive".
#   - **The cron path, end to end, including the host unit.** Firefly's
#     recurring transactions only fire when something calls
#     /api/v1/cron/<token>; nothing in the container does. The suite runs
#     nixos/configuration.nix's firefly-cron.service for real, and separately
#     pins the exactly-32-characters requirement that makes a near-miss token
#     return a 500 rather than an error anyone could act on.
#   - the importer's version gate against a real Firefly, and its own /health.
#   - the upload directory being writable by uid 33, which PUID/PGID do NOT
#     arrange here — the image ends on `USER www-data` at build time and never
#     runs an id-remap entrypoint, so only the tmpfiles rule can.
#   - the backup contract by executing it: `pg_dumpall -U firefly` inside
#     `firefly_db`, exactly as nixos/backup-prepare.sh builds it.
#   - loopback-only publishing for BOTH ports, with a positive control.
#   - reboot durability on a real disk.
#
# Documented gaps (a green run covers NONE of these):
#   - **The actual forward-auth hop.** Authentik lives on the VPS; the suite
#     supplies the header itself. What is proven is that Firefly consumes the
#     header the outpost sends, not that the outpost sends it.
#   - **Any import.** The importer holds no access token here (it can only be
#     minted through an authenticated browser session), and SimpleFIN needs a
#     bank. Its UI comes up and its version gate passes; nothing more.
#   - **Recurring transactions actually firing.** The cron endpoint is called
#     and returns success; no recurrence is configured to observe.

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
    images."fireflyiii_core_version-6_6_6"
    images."fireflyiii_data-importer_version-2_3_4"
    images."postgres_17_9-alpine"
  ];

  seedSrv = pkgs.runCommand "srv-seed-firefly" { } ''
    mkdir -p $out/stacks/firefly
    cp -r ${../../stacks/firefly}/. $out/stacks/firefly/
    chmod -R u+w $out/stacks/firefly
    # The working-tree cp -r can capture a developer's locally-decrypted
    # plaintext .env (gitignored on purpose) in the world-readable store.
    rm -f $out/stacks/firefly/.env
    rm -f $out/stacks/firefly/.sops.env.example
    cp ${../fixtures/firefly.sops.env} $out/stacks/firefly/.sops.env
  '';
in
pkgs.testers.runNixOSTest {
  name = "firefly";

  # Laravel's first-boot migration set is long and the image's own health
  # start_period is 300s. The driver's 3600s default would kill the VMs
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
            memoryMB = 4096;
            diskMB = 20480;
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
        # the reboot subtest asserts DATA durability — the accounts created
        # through the guard must survive.
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
          # The SAME set and ownership production declares in
          # nixos/hardware-configuration.nix; keep the two in sync by hand.
          # 33:33 on upload is the whole point — see the writability subtest.
          "d /mnt/fast/firefly 0755 root root -"
          "d /mnt/fast/firefly/upload 0755 33 33 -"
          "d /mnt/fast/firefly/pgdata 0755 root root -"
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
    import shlex

    FIREFLY = "docker compose -f /srv/stacks/firefly/compose.yaml -p firefly"
    BASE = "http://127.0.0.1:10303"
    IMPORTER = "http://127.0.0.1:10305"

    # Fixture value from tests/fixtures/firefly.sops.env — exactly 32 chars,
    # which Binder\CLIToken requires.
    CRON_TOKEN = "testfireflycrontokennotsecret000"

    # Two arbitrary strings. The first becomes the OWNER simply by arriving
    # first; the second demonstrates that nothing is validated.
    OWNER = "owner@test.invalid"
    INTRUDER = "someone-else@test.invalid"

    def diag(label):
        print("=== diagnostics: " + label + " ===")
        for cmd in [
            "docker ps -a",
            "docker logs firefly 2>&1 | tail -80",
            "docker logs firefly_db 2>&1 | tail -30",
            "docker logs firefly_importer 2>&1 | tail -40",
            "docker inspect --format '{{.State.Health.Status}}' firefly 2>&1",
            "ls -la /mnt/fast/firefly /mnt/fast/firefly/upload 2>&1",
            "df -h /var/lib/docker /mnt; free -m",
        ]:
            print("--- " + cmd)
            print(services_vm.execute(cmd)[1])

    def status(base, path, headers=None, timeout=60):
        cmd = ("curl -s -o /dev/null -w '%{http_code}' --max-redirs 0 "
               f"--max-time {timeout} ")
        for k, v in (headers or {}).items():
            cmd += f"-H {shlex.quote(k + ': ' + v)} "
        return int(services_vm.succeed(cmd + shlex.quote(base + path)).strip())

    def emails():
        """Accounts Firefly has created, straight from the database.

        Read from Postgres rather than through the API on purpose: Firefly's
        API authenticates with Passport under a different guard, so no
        header-authenticated request can enumerate users.
        """
        out = services_vm.succeed(
            "docker exec firefly_db psql -U firefly -d firefly -tAc "
            "'select email from users order by id'"
        )
        return [l.strip() for l in out.splitlines() if l.strip()]

    start_all()

    # -----------------------------------------------------------------------
    # boot chain + decrypt
    # -----------------------------------------------------------------------
    with subtest("decrypt-sops-envs produced a 0600 .env owned by arcane's uid"):
        services_vm.wait_for_unit("multi-user.target")
        services_vm.wait_for_unit("docker-network-homelab.service")
        services_vm.wait_until_succeeds(
            "test -s /srv/stacks/firefly/.env", timeout=120
        )
        stat = services_vm.succeed(
            "stat -c '%a %u:%g' /srv/stacks/firefly/.env"
        ).strip()
        assert stat == "600 1000:1000", f".env is {stat}, expected 600 1000:1000"
        for k in ["APP_KEY", "STATIC_CRON_TOKEN", "POSTGRES_PASSWORD",
                  "DB_PASSWORD"]:
            services_vm.succeed(f"grep -q '^{k}=.' /srv/stacks/firefly/.env")
        # Present and EMPTY: the personal access token can only be minted
        # through an authenticated browser session, so the shipping state is
        # "importer runs, cannot talk to Firefly yet".
        services_vm.succeed(
            "grep -qx 'FIREFLY_III_ACCESS_TOKEN=' /srv/stacks/firefly/.env"
        )

    with subtest("APP_KEY is exactly 32 characters"):
        # A wrong LENGTH fails as "Auth driver [remote_user_guard] ... is not
        # defined" — the encrypter throws during config resolution and guard
        # registration collapses downstream, so the error names the auth config
        # and says nothing about the key. Asserted here so a bad fixture is a
        # one-line failure instead of an afternoon.
        n = int(services_vm.succeed(
            "grep '^APP_KEY=' /srv/stacks/firefly/.env | cut -d= -f2- | tr -d '\\n' | wc -c"
        ).strip())
        assert n == 32, f"APP_KEY is {n} chars, must be exactly 32"

    services_vm.wait_for_unit("load-test-images.service")

    # -----------------------------------------------------------------------
    # the stack comes up
    # -----------------------------------------------------------------------
    with subtest("compose up brings every container to a healthy state"):
        try:
            services_vm.succeed(f"{FIREFLY} up -d --wait --wait-timeout 1800")
        except Exception:
            diag("compose up failed")
            raise

    with subtest("HEALTHCHECK_PATH is overridden to /health on both images"):
        # The images' HEALTHCHECK is `curl http://localhost:8080$HEALTHCHECK_PATH`,
        # so the fix is the environment variable and `docker inspect` of the
        # healthcheck Test would show the unexpanded string. Check the env.
        for c in ("firefly", "firefly_importer"):
            services_vm.succeed(
                "docker inspect --format "
                "'{{range .Config.Env}}{{println .}}{{end}}' "
                f"{c} | grep -qx 'HEALTHCHECK_PATH=/health'"
            )

    # -----------------------------------------------------------------------
    # the guard
    # -----------------------------------------------------------------------
    with subtest("no accounts exist before any header arrives"):
        assert emails() == [], f"unexpected pre-existing users: {emails()}"

    with subtest("the header spelling works and auto-creates the owner"):
        code = status(BASE, "/", headers={"X-Authentik-Email": OWNER})
        # 200 (dashboard) or a 302 into the app are both success; what must NOT
        # happen is the "unable to link you to a user" error page.
        assert code in (200, 302), f"GET / with the guard header returned {code}"
        assert OWNER in emails(), (
            f"no account was created for {OWNER}; users are {emails()}. "
            "AUTHENTICATION_GUARD_HEADER is not being read — check the "
            "HTTP_-prefixed CGI spelling."
        )

    with subtest("a request with NO header creates nothing"):
        status(BASE, "/")
        assert emails() == [OWNER], (
            f"a headerless request changed the user set: {emails()}"
        )

    with subtest("the guard validates NOTHING — any header value is an account"):
        # Pinned deliberately. This is why :10303 is published to 127.0.0.1
        # only and why the Caddy handle imports (protected): anything that can
        # reach this port can assert any identity it likes.
        status(BASE, "/", headers={"X-Authentik-Email": INTRUDER})
        assert set(emails()) == {OWNER, INTRUDER}, (
            f"expected both accounts to exist, got {emails()}. If Firefly has "
            "started validating the header, the security model here can be "
            "revisited — but do not assume it, check."
        )

    # -----------------------------------------------------------------------
    # the healthcheck lie
    # -----------------------------------------------------------------------
    with subtest("/healthcheck lies and /health does not"):
        # With the database gone: /healthcheck is answered by php-fpm's own
        # ping before Laravel runs, so it stays 200; /health runs User::count()
        # and cannot. This pair is the entire justification for setting
        # HEALTHCHECK_PATH, and neither half means anything without the other.
        services_vm.succeed("docker stop firefly_db")
        try:
            services_vm.wait_until_succeeds(
                f"curl -s -o /dev/null -w '%{{http_code}}' --max-time 20 {BASE}/health"
                " | grep -vqx 200",
                timeout=180,
            )
            ping = status(BASE, "/healthcheck")
            assert ping == 200, (
                f"/healthcheck returned {ping} with the database down. If it is "
                "no longer answered by php-fpm's ping, HEALTHCHECK_PATH=/health "
                "may no longer be necessary — verify before removing it."
            )
            services_vm.wait_until_succeeds(
                "docker inspect --format '{{.State.Health.Status}}' firefly "
                "| grep -qx unhealthy",
                timeout=300,
            )
        finally:
            services_vm.succeed("docker start firefly_db")
        services_vm.wait_until_succeeds(
            "docker inspect --format '{{.State.Health.Status}}' firefly "
            "| grep -qx healthy",
            timeout=600,
        )

    # -----------------------------------------------------------------------
    # cron
    # -----------------------------------------------------------------------
    with subtest("the cron endpoint accepts the 32-character token"):
        code = status(BASE, f"/api/v1/cron/{CRON_TOKEN}", timeout=180)
        assert code == 200, f"cron endpoint returned {code}"

    with subtest("a near-miss token is rejected — why the length is pinned"):
        code = status(BASE, f"/api/v1/cron/{CRON_TOKEN[:31]}", timeout=180)
        assert code != 200, (
            "a 31-character token was accepted; the exactly-32 check in "
            "Binder\\CLIToken is gone and the .sops.env warning is now wrong"
        )

    with subtest("firefly-cron.service runs the real host unit"):
        # The unit ships in nixos/configuration.nix and reads the token out of
        # /srv/stacks/firefly/.env itself, so this exercises the whole path
        # including the file-not-present and wrong-length guards.
        services_vm.succeed("systemctl start firefly-cron.service")
        out = services_vm.succeed("systemctl show -p Result firefly-cron.service")
        assert "Result=success" in out, out

    # -----------------------------------------------------------------------
    # the importer
    # -----------------------------------------------------------------------
    with subtest("the importer serves and its version gate passes"):
        assert status(IMPORTER, "/health") == 200
        # Its UI is what the version gate runs behind; a core older than
        # 6.6.0 makes this page an error rather than a form.
        code = status(IMPORTER, "/")
        assert code in (200, 302), f"importer / returned {code}"
        logs = services_vm.succeed("docker logs firefly_importer 2>&1")
        assert "minimum version" not in logs.lower(), logs[-3000:]

    # -----------------------------------------------------------------------
    # uid 33, which PUID/PGID do not arrange here
    # -----------------------------------------------------------------------
    with subtest("the upload directory is writable by www-data"):
        # PUID/PGID are INERT in this image: it ends on `USER www-data` at
        # build time and never invokes an id-remap entrypoint, so only the
        # tmpfiles rule can make this work. Getting it wrong produces a
        # container that starts, serves, and fails only when someone attaches
        # a receipt — months later.
        services_vm.succeed(
            "docker exec firefly sh -c "
            "'touch /var/www/html/storage/upload/.probe && "
            "rm /var/www/html/storage/upload/.probe'"
        )
        owner = services_vm.succeed(
            "stat -c '%u:%g' /mnt/fast/firefly/upload"
        ).strip()
        assert owner == "33:33", f"upload dir is {owner}, expected 33:33"

    # -----------------------------------------------------------------------
    # backup contract, executed rather than asserted about
    # -----------------------------------------------------------------------
    with subtest("backup-prepare's pg_dumpall contract holds"):
        # Exactly how nixos/backup-prepare.sh builds it: container "<svc>_db",
        # `pg_dumpall -U <svc>`.
        # Redirected to a file rather than piped to `head`: pg_dumpall keeps
        # writing after head closes the pipe, so the pipeline exits 141
        # (SIGPIPE) and `succeed` treats a perfectly good dump as a failure.
        services_vm.succeed(
            "docker exec firefly_db pg_dumpall -U firefly > /tmp/firefly.sql"
        )
        out = services_vm.succeed("head -40 /tmp/firefly.sql")
        assert "CREATE ROLE" in out or "ROLE firefly" in out, out

    # -----------------------------------------------------------------------
    # publishing
    # -----------------------------------------------------------------------
    with subtest("10303 and 10305 are loopback-only, with a positive control"):
        ip = services_vm.succeed(
            "ip -4 -o addr show eth1 | awk '{print $4}' | cut -d/ -f1"
        ).strip()
        outsider.wait_for_unit("network.target")
        # 10303 matters most: anything that reaches it can assert any identity.
        outsider.fail(f"curl -s --max-time 10 http://{ip}:10303/ >/dev/null")
        # 10305 matters nearly as much: the importer has no auth of its own.
        outsider.fail(f"curl -s --max-time 10 http://{ip}:10305/ >/dev/null")
        # Positive control: the outsider can reach the VM at all, so the
        # failures above are the binding and not a dead network.
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
            "test -s /srv/stacks/firefly/.env", timeout=180
        )
        services_vm.wait_for_unit("load-test-images.service")
        services_vm.succeed(f"{FIREFLY} up -d --wait --wait-timeout 1800")
        assert set(emails()) == {OWNER, INTRUDER}, (
            f"accounts did not survive the reboot: {emails()}"
        )
  '';
}
