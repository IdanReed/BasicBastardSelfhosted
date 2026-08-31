# Windmill suite: server, worker, Postgres, and the one-shot that retires the
# published default account.
#
# Hand-written because the two assertions that matter here cannot be expressed
# generically: one is about the CONTENTS of a docker volume, and the other is a
# negative about a credential that ships live.
#
# Genuinely under test:
#   - 🚨 **The dependency cache really was seeded.** The image bakes CPython
#     3.11 and 3.12 into /tmp/windmill/cache/py_runtime at build time. A NAMED
#     volume is seeded from the image on first use; a bind mount is never
#     seeded and silently shadows the directory with an empty host path. With
#     UV_PYTHON_PREFERENCE=only-managed there is no system fallback, so the
#     "obvious" fleet-convention translation to /mnt/fast/windmill/cache would
#     make the first Python job try to download an interpreter — egress this
#     host does not have. The suite looks inside the volume for the
#     interpreters, because nothing about a healthy container reveals this.
#   - 🚨 **`admin@windmill.dev` / `changeme` no longer works.** Windmill seeds
#     that account and does NOT force a password change, so upstream's
#     documented setup leaves a published credential live until a human opens
#     the UI. The suite proves the real superadmin authenticates AND that the
#     default does not.
#   - **The worker actually registered.** It has no HTTP listener and therefore
#     no honest container healthcheck — `pgrep` would be exactly the process
#     check finding #16 warns about — so its liveness is asserted from the
#     SERVER's worker list, which is the only place the answer lives.
#   - windmill_init's idempotence: a redeploy logs zero CHANGE lines.
#   - the backup contract executed, not asserted about: `pg_dumpall -U
#     windmill` inside `windmill_db`, exactly as backup-prepare.sh builds it.
#   - loopback-only publishing, with a positive control.
#
# Documented gaps (a green run covers NONE of these):
#   - **Running an actual job.** Proving a Python script executes would need
#     the worker to resolve dependencies, and anything beyond the stdlib needs
#     egress. What is proven is that the interpreters the worker would use are
#     present.
#   - **Forward auth.** It gates access only and needs the VPS outpost;
#     Windmill never sees X-Authentik-* either way.
#   - **The GPU/Ollama worker legs** on the desktop, which are out of scope for
#     this campaign entirely.

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
    images."ghcr_io_windmill-labs_windmill_1_798_1" # server, worker
    images."postgres_17_9-alpine"
    images."python_3_13-alpine" # windmill_init
  ];

  seedSrv = pkgs.runCommand "srv-seed-windmill" { } ''
    mkdir -p $out/stacks/windmill
    cp -r ${../../stacks/windmill}/. $out/stacks/windmill/
    chmod -R u+w $out/stacks/windmill
    rm -f $out/stacks/windmill/.env
    rm -f $out/stacks/windmill/.sops.env.example
    cp ${../fixtures/windmill.sops.env} $out/stacks/windmill/.sops.env
  '';
in
pkgs.testers.runNixOSTest {
  name = "windmill";

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
            memoryMB = 6144;
            diskMB = 24576;
          })
          (profiles.loadImages {
            inherit pkgs;
            images = stackImages;
            beforeUnits = [ "multi-user.target" ];
          })
        ];

        systemd.services.bootstrap-arcane.wantedBy = lib.mkForce [ ];
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
          # Only pgdata. The dependency cache is a NAMED VOLUME and must never
          # get a rule here — see the cache subtest for what a bind mount does.
          "d /mnt/fast/windmill 0755 root root -"
          "d /mnt/fast/windmill/pgdata 0755 root root -"
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
    import shlex

    WM = "docker compose -f /srv/stacks/windmill/compose.yaml -p windmill"
    BASE = "http://127.0.0.1:10253"

    # Fixture values from tests/fixtures/windmill.sops.env.
    ADMIN = "wm-admin@test.invalid"
    ADMIN_PASS = "test_windmill_admin_password_not_secret"

    # What Windmill seeds and does NOT force you to change.
    DEFAULT_ADMIN = "admin@windmill.dev"
    DEFAULT_PASS = "changeme"

    def diag(label):
        print("=== diagnostics: " + label + " ===")
        for cmd in [
            "docker ps -a",
            "docker logs windmill_server 2>&1 | tail -60",
            "docker logs windmill_worker 2>&1 | tail -40",
            "docker logs windmill_init 2>&1 | tail -40",
            "docker logs windmill_db 2>&1 | tail -20",
            "df -h /var/lib/docker /mnt; free -m",
        ]:
            print("--- " + cmd)
            print(services_vm.execute(cmd)[1])

    def login(email, password):
        """Returns (status, body). Not -f: 401 is a real answer here."""
        code = services_vm.succeed(
            "curl -sS -o /tmp/wmbody -w '%{http_code}' --max-time 30 -X POST "
            "-H 'Content-Type: application/json' "
            f"-d {shlex.quote(json.dumps({'email': email, 'password': password}))} "
            f"{BASE}/api/auth/login"
        ).strip()
        return int(code), services_vm.succeed("cat /tmp/wmbody").strip()

    start_all()

    with subtest("decrypt-sops-envs produced a 0600 .env owned by arcane's uid"):
        services_vm.wait_for_unit("multi-user.target")
        services_vm.wait_for_unit("docker-network-homelab.service")
        services_vm.wait_until_succeeds("test -s /srv/stacks/windmill/.env", timeout=120)
        stat = services_vm.succeed("stat -c '%a %u:%g' /srv/stacks/windmill/.env").strip()
        assert stat == "600 1000:1000", f".env is {stat}"
        for k in ["DATABASE_URL", "SUPERADMIN_SECRET", "WINDMILL_ADMIN_EMAIL",
                  "WINDMILL_ADMIN_PASSWORD"]:
            services_vm.succeed(f"grep -q '^{k}=.' /srv/stacks/windmill/.env")

    services_vm.wait_for_unit("load-test-images.service")

    with subtest("compose up brings the server and database healthy"):
        # The worker has NO healthcheck (`disable: true`) on purpose: it has no
        # HTTP listener, so any container-level probe would be a process check
        # of the kind finding #16 exists to warn about. Its liveness is
        # asserted from the server below.
        try:
            services_vm.succeed(f"{WM} up -d --wait --wait-timeout 1200 windmill_server windmill_worker windmill_db")
        except Exception:
            diag("compose up failed")
            raise

    with subtest("both containers run as uid 1000, not root"):
        # Without this the image runs as root and executes arbitrary user
        # scripts as root, with the docker client, crane, nsjail and kubectl on
        # $PATH. HOME=/tmp is the other required half.
        for c in ("windmill_server", "windmill_worker"):
            u = services_vm.succeed(
                f"docker inspect --format '{{{{.Config.User}}}}' {c}"
            ).strip()
            assert u == "1000:1000", f"{c} runs as {u!r}"
            env = services_vm.succeed(
                "docker inspect --format "
                f"'{{{{range .Config.Env}}}}{{{{println .}}}}{{{{end}}}}' {c}"
            )
            assert "HOME=/tmp" in env, f"{c} is missing HOME=/tmp"

    with subtest("🚨 the dependency cache was SEEDED — the named-volume contract"):
        # The single most consequential assertion in this suite. The image
        # bakes CPython 3.11 and 3.12 into this path; a named volume inherits
        # them on first use, a bind mount does not. Nothing about a healthy
        # container reveals the difference — it surfaces as the first Python
        # job hanging on `uv python install` against a network that is not
        # there.
        out = services_vm.succeed(
            "docker exec windmill_worker sh -c "
            "'ls /tmp/windmill/cache/py_runtime 2>&1 || true'"
        )
        assert "cpython-3.11" in out and "cpython-3.12" in out, (
            f"py_runtime holds {out!r}. The dependency cache was NOT seeded, "
            "which means the volume is a bind mount rather than a named "
            "volume — UV_PYTHON_PREFERENCE=only-managed forbids a system "
            "fallback, so every Python job will try to download an "
            "interpreter and hang."
        )
        # And prove it is genuinely a named volume, not merely populated.
        mounts = services_vm.succeed(
            "docker inspect --format '{{json .Mounts}}' windmill_worker"
        )
        assert '"Type":"volume"' in mounts.replace(" ", ""), mounts

    with subtest("windmill_init exited 0 and reported its changes"):
        services_vm.wait_until_succeeds(
            "docker inspect --format '{{.State.Status}}' windmill_init "
            "| grep -qx exited",
            timeout=900,
        )
        rc = services_vm.succeed(
            "docker inspect --format '{{.State.ExitCode}}' windmill_init"
        ).strip()
        assert rc == "0", f"windmill_init exited {rc}"
        logs = services_vm.succeed("docker logs windmill_init 2>&1")
        assert "CHANGE: created superadmin" in logs, logs
        assert "done" in logs, logs

    with subtest("the real superadmin authenticates"):
        code, body = login(ADMIN, ADMIN_PASS)
        assert code < 300, f"login returned {code}: {body[:300]}"
        token = body.strip().strip('"')
        assert token, "login returned an empty token"

    with subtest("🚨 admin@windmill.dev / changeme does NOT"):
        # Windmill seeds this account and never forces a password change, so
        # upstream's own documented setup leaves a PUBLISHED credential live on
        # a service whose purpose is running arbitrary code. If windmill_init
        # silently did nothing, every other assertion here would still pass.
        code, body = login(DEFAULT_ADMIN, DEFAULT_PASS)
        assert code >= 400, (
            f"{DEFAULT_ADMIN}/{DEFAULT_PASS} still authenticates ({code}): "
            f"{body[:300]}"
        )

    with subtest("the worker registered with the server"):
        code, body = login(ADMIN, ADMIN_PASS)
        token = body.strip().strip('"')
        services_vm.wait_until_succeeds(
            f"curl -sf --max-time 20 -H {shlex.quote('Authorization: Bearer ' + token)} "
            f"{BASE}/api/workers/list | grep -q worker",
            timeout=300,
        )

    with subtest("windmill_init is idempotent — a redeploy changes nothing"):
        services_vm.succeed("docker rm -f windmill_init")
        services_vm.succeed(f"{WM} up -d windmill_init")
        services_vm.wait_until_succeeds(
            "docker inspect --format '{{.State.Status}}' windmill_init "
            "| grep -qx exited",
            timeout=600,
        )
        rc = services_vm.succeed(
            "docker inspect --format '{{.State.ExitCode}}' windmill_init"
        ).strip()
        assert rc == "0", f"second windmill_init run exited {rc}"
        logs = services_vm.succeed("docker logs windmill_init 2>&1")
        assert "CHANGE:" not in logs, f"second run mutated something:\n{logs}"

    with subtest("backup-prepare's pg_dumpall contract holds"):
        # Exactly how nixos/backup-prepare.sh builds it. Upstream's compose
        # uses POSTGRES_USER=postgres; the rename to `windmill` is what makes
        # the loop work, and this is what keeps a future "normalise it back"
        # from silently emptying the dump.
        # Redirected to a file rather than piped to `head`: pg_dumpall keeps
        # writing after head closes the pipe, so the pipeline exits 141
        # (SIGPIPE) and `succeed` treats a perfectly good dump as a failure.
        services_vm.succeed(
            "docker exec windmill_db pg_dumpall -U windmill > /tmp/windmill.sql"
        )
        out = services_vm.succeed("head -40 /tmp/windmill.sql")
        assert "CREATE ROLE" in out or "ROLE windmill" in out, out

    with subtest("10253 is loopback-only, with a positive control"):
        ip = services_vm.succeed(
            "ip -4 -o addr show eth1 | awk '{print $4}' | cut -d/ -f1"
        ).strip()
        outsider.wait_for_unit("network.target")
        outsider.fail(f"curl -s --max-time 10 http://{ip}:10253/ >/dev/null")
        outsider.succeed(f"ping -c1 -W5 {ip} >/dev/null")

    with subtest("state survives a reboot"):
        # shutdown()+start(), not reboot(): qemu runs with -no-reboot.
        services_vm.shutdown()
        services_vm.start()
        services_vm.wait_for_unit("multi-user.target")
        services_vm.wait_until_succeeds("test -s /srv/stacks/windmill/.env", timeout=180)
        services_vm.wait_for_unit("load-test-images.service")
        services_vm.succeed(f"{WM} up -d --wait --wait-timeout 1200 windmill_server windmill_worker windmill_db")
        code, _ = login(ADMIN, ADMIN_PASS)
        assert code < 300, f"post-reboot login returned {code}"
        code, _ = login(DEFAULT_ADMIN, DEFAULT_PASS)
        assert code >= 400, "the default account came back after a reboot"
  '';
}
