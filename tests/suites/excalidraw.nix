# Excalidraw (AstraDraw) suite — hand-written, though all four containers are
# restart: unless-stopped with no oneshots, so mk-stack-suite would also boot
# it (and `run.sh stack excalidraw` remains the fast loop). The generic
# harness proves "containers healthy"; this stack's THE claim — a named scene
# persists SERVER-SIDE and comes back after a restart — is exactly what a
# green healthcheck cannot see, for a specific measured reason: with
# STORAGE_URI missing the api logs one WARN and silently stores every scene
# in process MEMORY. Healthy container, working UI, all saves lost on
# restart. Only a write -> inspect-postgres -> restart -> read-back cycle
# distinguishes the two, and that cycle is this suite.
#
# Genuinely under test:
#   - 🚨 **The persistence round trip, through Postgres.** Login as the
#     seeded admin, create a NAMED scene, prove the blob landed in the keyv
#     table (not memory), restart the api container, read the same bytes
#     back. This is the reason the stack exists.
#   - 🚨 **The keyv CREATE-TABLE race stays defused — in a SEPARATE
#     database.** @keyv/postgres races its lazy CREATE across the api's four
#     boot-time connections and the loser is broken until the next restart
#     (measured: boots coin-flip). keyv-init.sql pre-creates the table from
#     postgres's initdb hook — in its own `excalidraw_storage` db, because
#     pre-creating it in Prisma's db makes `migrate deploy` fail P3005 on
#     every boot and the entrypoint's `db push --accept-data-loss` fallback
#     then DROPS the blob table each restart (also measured — silent loss of
#     every scene). Asserted here as (a) the table exists in the storage db,
#     (b) no P3005 and a populated _prisma_migrations in Prisma's db, and
#     (c) ZERO "Connection Error" lines across BOTH api boots this suite
#     performs.
#   - 🚨 **Fully offline boot** — the ExcaliDash trap, absent: the VM has no
#     route out, so `prisma migrate deploy` completing proves the CLI and
#     engines are baked into the image, not fetched.
#   - **The auth posture**: local auth on, registration CLOSED (a register
#     attempt is refused and cannot log in afterwards), OIDC off, wrong
#     password 401s, anonymous workspace API 401s.
#   - **Runtime env injection**: env-config.js carries the real vhost URLs
#     and no __VITE_APP placeholders — the property that makes the PREBUILT
#     frontend image deployable here at all.
#   - **The collab relay speaks Engine.IO** on 10408 (handshake with a sid),
#     not merely accepts TCP.
#   - **pgdata lands where backup-prepare.sh's pg_dumpall loop expects**
#     (container excalidraw_db, role excalidraw, db excalidraw — the loop
#     derives all three from the stack name).
#   - **10406/10408/10409 are unreachable from another machine.**
#
# Documented gaps:
#   - **No browser, so no end-to-end collab.** Two clients editing one scene
#     needs two browsers; the suite proves the relay's handshake and the
#     api's scene/room endpoints, not multi-user merge. First deploy: open a
#     scene in two tabs, draw in one, watch the other.
#   - **Vhost path routing is not exercised** — no Caddy here. The three-way
#     /, /socket.io, /api/v2 split is asserted only as "each upstream
#     answers on its loopback port".
#   - **OIDC turn-on.** Needs the VPS and a client secret; only the OFF
#     state is pinned. Discovery behaviour against a dead issuer is
#     UNMEASURED for this app — check before enabling (see compose.yaml).
#   - **CDN font fallback** is a browser behaviour; the local woff2 files'
#     presence in the image is relied on, not asserted.

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
    images."astradraw_app_1_0_1"
    images."astradraw_room_1_0_1"
    images."astradraw_api_1_0_1"
    images."postgres_17_9-alpine"
  ];

  fixture = ../fixtures/excalidraw.sops.env;

  seedSrv = pkgs.runCommand "srv-seed-excalidraw" { } ''
    mkdir -p $out/stacks/excalidraw
    cp -r ${../../stacks/excalidraw}/. $out/stacks/excalidraw/
    chmod -R u+w $out/stacks/excalidraw
    # A locally-decrypted plaintext .env is gitignored but would still be
    # captured by cp -r into the world-readable store.
    rm -f $out/stacks/excalidraw/.env
    rm -f $out/stacks/excalidraw/.sops.env.example $out/stacks/excalidraw/.sops.env
    cp ${fixture} $out/stacks/excalidraw/.sops.env
  '';

  # /mnt tmpfiles rules from the SAME generated file the real host imports
  # (nixos/stack-dirs.nix), never hand-copied — the wealthfolio/mk-stack-suite
  # pattern. The postgres image chowns its own datadir (root:root rule is
  # correct here), but reading the generated file keeps this suite from
  # asserting its own fixture if that ever changes.
  stackMntRoots = [ "/mnt/fast/excalidraw/pgdata" ];
  stackDirRules = (import ../../nixos/stack-dirs.nix).systemd.tmpfiles.rules;
  rulePath = r: lib.elemAt (lib.splitString " " r) 1;
  # Keep the rule for each root AND its ancestors — a parent directory
  # created implicitly by tmpfiles gets default ownership, not the rule's.
  covers = dir: p: p == dir || lib.hasPrefix (dir + "/") p;
  missingRoots = lib.filter (root: !(lib.any (r: rulePath r == root) stackDirRules)) stackMntRoots;
  mntRules =
    if missingRoots == [ ] then
      lib.filter (r: lib.any (covers (rulePath r)) stackMntRoots) stackDirRules
    else
      throw (
        "excalidraw suite: nixos/stack-dirs.nix has no rule for "
        + lib.concatStringsSep ", " missingRoots
        + " — add the STACK_NOTES/DIR_NOTES entries and re-run nixos/generate-stack-dirs.sh"
      );
in
pkgs.testers.runNixOSTest {
  name = "excalidraw";

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
            diskMB = 8192;
          })
          (profiles.loadImages {
            inherit pkgs;
            images = stackImages;
            beforeUnits = [ "multi-user.target" ];
          })
        ];

        systemd.services.bootstrap-komodo.wantedBy = lib.mkForce [ ];
        # The stack-git-sync timer would fail its clone every tick with no Forgejo here.
        systemd.timers.stack-git-sync.wantedBy = lib.mkForce [ ];
        virtualisation.cores = lib.mkForce 2;

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
          "d /srv/stacks 0755 1000 1000 -"
          "d /var/lib/sops-nix 0700 root root -"
        ]
        ++ mntRules;

        systemd.services.seed-srv = {
          description = "Seed /srv with the excalidraw stack (test only)";
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
          curl
        ];
      };

    # curl EXPLICITLY: the outsider only ever runs it inside .fail(), and a
    # node without curl makes that negative pass vacuously.
    outsider =
      { pkgs, ... }:
      {
        environment.systemPackages = [ pkgs.curl ];
      };
  };

  testScript = ''
    EX = "docker compose -f /srv/stacks/excalidraw/compose.yaml -p excalidraw"
    API = "http://127.0.0.1:10409/api/v2"
    APP = "http://127.0.0.1:10406"
    ROOM = "http://127.0.0.1:10408"
    PASSWORD = "test_excalidraw_admin_password_not_secret"

    def dump_diag():
        for label, cmd in [
            ("compose ps", f"{EX} ps -a"),
            ("api logs", "docker logs excalidraw_api 2>&1 | tail -50"),
            ("db logs", "docker logs excalidraw_db 2>&1 | tail -30"),
            ("decrypt journal",
             "journalctl -u decrypt-sops-envs --no-pager -o cat | tail -20"),
            ("data dir", "ls -la /mnt/fast/excalidraw/pgdata | head -10"),
        ]:
            print(f"--- {label} ---")
            print(services_vm.execute(cmd)[1])

    start_all()

    services_vm.wait_for_unit("multi-user.target")
    services_vm.wait_for_unit("docker-network-homelab.service")
    services_vm.wait_for_unit("load-test-images.service")

    try:
        with subtest("the fixture .sops.env decrypted to a 0600 .env"):
            # The artifact, not the unit: decrypt-sops-envs is a transient
            # oneshot on a minutely timer, so waiting on the unit races its
            # inactive-after-success state (mk-stack-suite's rule).
            services_vm.wait_until_succeeds(
                "test -s /srv/stacks/excalidraw/.env", timeout=90
            )
            mode = services_vm.succeed(
                "stat -c %a /srv/stacks/excalidraw/.env"
            ).strip()
            assert mode == "600", f".env is mode {mode}, expected 600"

        with subtest("🚨 the stack comes up healthy, fully OFFLINE"):
            # No route out of this VM exists — so `--wait` reaching healthy
            # proves boot needs no registry and, the ExcaliDash lesson, that
            # `prisma migrate deploy` ran from BAKED CLI + engines rather
            # than npx-downloading anything. Four services, no oneshots:
            # --wait is safe (finding #39 does not apply).
            services_vm.succeed(f"{EX} up -d --wait --wait-timeout 300")
            services_vm.wait_until_succeeds(
                f"curl -fsS --max-time 10 {API}/auth/status | jq -e .localAuthEnabled",
                timeout=120,
            )

        with subtest("🚨 keyv table pre-created by initdb, in its OWN database"):
            # keyv-init.sql must have run before the api's four keyv
            # connections ever connected; to_regclass is NULL-safe (no error
            # on a missing table, just 'f'). The database name matters as
            # much as the table: in Prisma's own db this table gets DROPPED
            # by the entrypoint's db-push fallback on every boot (measured —
            # see keyv-init.sql), which is silent scene loss.
            services_vm.succeed(
                "docker exec excalidraw_db psql -U excalidraw -d excalidraw_storage "
                "-tAc \"SELECT to_regclass('public.keyv') IS NOT NULL\" "
                "| grep -qx t"
            )
            # And Prisma's own database took the REAL migrations — P3005 is
            # the signature of the poisoned chain (migrate refused, db push
            # ran); its absence plus a populated history table proves deploy
            # succeeded first try.
            out = services_vm.execute(
                "docker logs excalidraw_api 2>&1 | grep -c P3005"
            )[1].strip()
            assert out == "0", f"prisma migrate deploy hit P3005 {out} time(s) — the db-push shredder chain is live"
            services_vm.succeed(
                "docker exec excalidraw_db psql -U excalidraw -d excalidraw "
                "-tAc 'SELECT count(*) FROM _prisma_migrations' "
                "| grep -qvx 0"
            )
            # And the defusal WORKED: a lost race logs 'Connection Error for
            # namespace <x>' at boot and breaks that namespace until restart
            # (measured against astradraw/api:1.0.1 without the init file).
            out = services_vm.execute(
                "docker logs excalidraw_api 2>&1 | grep -c 'Connection Error'"
            )[1].strip()
            assert out == "0", f"keyv logged {out} Connection Error line(s) at first boot"

        with subtest("auth posture pinned: local on, registration CLOSED, OIDC off"):
            services_vm.succeed(
                f"curl -fsS --max-time 10 {API}/auth/status "
                "| jq -e '.oidcConfigured == false and .localAuthEnabled == true "
                "and .registrationEnabled == false'"
            )

        with subtest("a register attempt is refused and mints no account"):
            # Measured against the pinned image with ENABLE_REGISTRATION=
            # false: this body yields 400 (validation and the disabled gate
            # both refuse; either way no account). The login that follows is
            # the assertion that actually matters — whatever the status was,
            # nothing was created that can authenticate.
            code = services_vm.succeed(
                "curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "
                "-X POST -H 'Content-Type: application/json' "
                "-d '{\"email\":\"intruder@example.invalid\","
                "\"password\":\"hunter22hunter22\",\"name\":\"Intruder\"}' "
                f"{API}/auth/register"
            ).strip()
            assert code in ("400", "403"), f"register gave {code}, expected 400/403"
            code = services_vm.succeed(
                "curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "
                "-X POST -H 'Content-Type: application/json' "
                "-d '{\"username\":\"intruder@example.invalid\","
                "\"password\":\"hunter22hunter22\"}' "
                f"{API}/auth/login/local"
            ).strip()
            assert code == "401", f"intruder login gave {code}, expected 401"

        with subtest("wrong admin password 401s; anonymous workspace API 401s"):
            code = services_vm.succeed(
                "curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "
                "-X POST -H 'Content-Type: application/json' "
                "-d '{\"username\":\"admin\",\"password\":\"wrong-password\"}' "
                f"{API}/auth/login/local"
            ).strip()
            assert code == "401", f"wrong password gave {code}, expected 401"
            code = services_vm.succeed(
                "curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "
                f"{API}/workspace/scenes"
            ).strip()
            assert code == "401", f"anonymous scene list gave {code}, expected 401"

        with subtest("the seeded admin logs in (fixture password survived decrypt)"):
            # The astradraw_token cookie is Secure (NODE_ENV=production), so
            # curl's jar refuses to REPLAY it over plain http — read it out
            # of the response headers and send it back by hand instead. The
            # api does not care; only the jar does.
            services_vm.succeed(
                "curl -fsS -D /tmp/ex-headers -o /tmp/ex-login.json --max-time 10 "
                "-X POST -H 'Content-Type: application/json' "
                "-d '{\"username\":\"admin\",\"password\":\"" + PASSWORD + "\"}' "
                f"{API}/auth/login/local"
            )
            services_vm.succeed("jq -e '.success == true' /tmp/ex-login.json")
            cookie = services_vm.succeed(
                "sed -n 's/^[Ss]et-[Cc]ookie: *\\(astradraw_token=[^;]*\\).*/\\1/p' "
                "/tmp/ex-headers"
            ).strip()
            assert cookie.startswith("astradraw_token="), f"no session cookie in: {cookie!r}"
            services_vm.succeed(
                f"curl -fsS --max-time 10 -H 'Cookie: {cookie}' {API}/auth/me "
                "| jq -e '.email == \"admin@idanreed.com\"'"
            )

        with subtest("🚨 a NAMED scene persists SERVER-SIDE — into Postgres, not memory"):
            # The core claim of the whole stack. The payload is a plain
            # string on purpose: the api stores dto.data verbatim as a blob
            # and serves it back as octet-stream, so an exact-match grep is
            # a byte-for-byte round trip.
            scene = services_vm.succeed(
                "curl -fsS --max-time 10 -X POST "
                f"-H 'Cookie: {cookie}' -H 'Content-Type: application/json' "
                "-d '{\"title\":\"suite-scene\",\"data\":\"suite-marker-payload-v1\"}' "
                f"{API}/workspace/scenes | jq -r .id"
            ).strip()
            assert scene, "scene create returned no id"
            # The scene is listed by NAME — the 'reopen it later' workspace
            # property, distinct from share-link persistence.
            services_vm.succeed(
                f"curl -fsS --max-time 10 -H 'Cookie: {cookie}' {API}/workspace/scenes "
                "| jq -e '.[] | select(.title == \"suite-scene\")'"
            )
            services_vm.succeed(
                f"curl -fsS --max-time 10 -H 'Cookie: {cookie}' "
                f"{API}/workspace/scenes/{scene}/data "
                "| grep -qx suite-marker-payload-v1"
            )
            # 🚨 And the blob is IN THE STORAGE DATABASE. This is the
            # assertion that distinguishes real persistence from the
            # measured in-memory fallback (STORAGE_URI missing): both serve
            # the bytes back, only one survives a restart.
            count = services_vm.succeed(
                "docker exec excalidraw_db psql -U excalidraw -d excalidraw_storage "
                "-tAc \"SELECT count(*) FROM public.keyv WHERE key LIKE 'scenes:%'\""
            ).strip()
            assert count == "1", f"expected 1 scene blob in postgres, found {count}"

        with subtest("🚨 the scene survives an api restart"):
            services_vm.succeed("docker restart excalidraw_api")
            services_vm.wait_until_succeeds(
                "test \"$(docker inspect -f '{{.State.Health.Status}}' "
                "excalidraw_api)\" = healthy",
                timeout=120,
            )
            # Same JWT cookie: still valid across the restart (stateless
            # sessions signed by JWT_SECRET), and the data comes back from
            # Postgres byte-identical.
            services_vm.succeed(
                f"curl -fsS --max-time 10 -H 'Cookie: {cookie}' "
                f"{API}/workspace/scenes/{scene}/data "
                "| grep -qx suite-marker-payload-v1"
            )
            # The race tripwire again, now across BOTH boots: the second
            # boot is exactly where the un-defused race bit (measured:
            # first boot fine, restart coin-flips).
            out = services_vm.execute(
                "docker logs excalidraw_api 2>&1 | grep -c 'Connection Error'"
            )[1].strip()
            assert out == "0", f"keyv logged {out} Connection Error line(s) across restarts"

        with subtest("frontend runtime injection produced the real vhost config"):
            # The property that makes a PREBUILT Vite image deployable: the
            # entrypoint wrote env-config.js with our URLs, placeholders gone.
            services_vm.succeed(
                f"curl -fsS --max-time 10 {APP}/env-config.js "
                "| grep -q 'https://excalidraw.svc.idanreed.com'"
            )
            out = services_vm.execute(
                f"curl -fsS --max-time 10 {APP}/env-config.js | grep -c __VITE_APP"
            )[1].strip()
            assert out == "0", "env-config.js still contains __VITE_APP placeholders"
            # The SPA shell itself serves.
            services_vm.succeed(f"curl -fsS --max-time 10 -o /dev/null {APP}/")

        with subtest("the collab relay answers an Engine.IO handshake"):
            # A real protocol exchange (session id in the response), not a
            # bare TCP accept — the same probe the container healthcheck
            # runs, asserted here with content.
            services_vm.succeed(
                f"curl -fsS --max-time 10 '{ROOM}/socket.io/?EIO=4&transport=polling' "
                "| grep -q '\"sid\"'"
            )

        with subtest("pgdata landed where backup-prepare.sh will look"):
            # The pg_dumpall loop derives container excalidraw_db and role
            # excalidraw from the stack name; the datadir existing under
            # /mnt/fast is what the Backrest exclusion + dump pairing is FOR.
            services_vm.succeed("test -f /mnt/fast/excalidraw/pgdata/PG_VERSION")

        with subtest("🚨 10406/10408/10409 are unreachable from another machine"):
            ip = services_vm.succeed(
                "ip -4 -o addr show eth1 | awk '{print $4}' | cut -d/ -f1"
            ).strip()
            outsider.wait_for_unit("network.target")
            outsider.succeed(f"ping -c1 -W5 {ip} >/dev/null")
            for port in (10406, 10408, 10409):
                outsider.fail(
                    f"curl -s --max-time 10 http://{ip}:{port}/ >/dev/null"
                )

        with subtest("everything still healthy at the end"):
            for name in ("excalidraw", "excalidraw_room", "excalidraw_api", "excalidraw_db"):
                services_vm.succeed(
                    "test \"$(docker inspect -f '{{.State.Health.Status}}' "
                    + name + ")\" = healthy"
                )
    except Exception:
        dump_diag()
        raise
  '';
}
