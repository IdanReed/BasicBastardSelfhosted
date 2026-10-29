# Penpot suite — the claims a green `run.sh stack penpot` cannot make. The
# generic harness proves five containers healthy and the one publish
# loopback-only; this one proves the stack is the one the compose header
# describes: OIDC the only way in, nothing minted by anyone else, and a boot
# that needs no network.
#
# Genuinely under test:
#   - 🚨 **The OIDC contract, offline.** With every endpoint given and no
#     discovery, the backend hands out Authentik's authorize URL with
#     client_id `penpot` and the redirect URI penpot-oidc.yaml registers —
#     strict matching, so a drift is a login-time failure.
#   - 🚨 **Password login and password registration are refused**, and no
#     profile exists after the attempts.
#   - **Fully offline boot** — migrations applied to the fleet's Postgres 17
#     (upstream ships 15), the air-gapped frontend nginx starting with no DNS
#     for public hosts, the flags and SSO label written into config.js.
#   - **Wiring**: env.nix's two built values in the env, nginx reaching the
#     backend (/readyz through the publish), the exporter reaching the
#     frontend by its service name, assets writable by the backend and
#     read-only to the frontend, `pg_dumpall -U penpot` against penpot_db as
#     backup-prepare.sh runs it.
#   - **10410 unreachable from another machine.**
#
# Documented gaps:
#   - **No real Authentik**: the token exchange, the groups-claim role check
#     and the first-login "confirm your name" page need a browser and the VPS.
#     First deploy: log in once through SSO and create one file.
#   - **No export**: rendering needs a logged-in session.

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
    images."penpotapp_frontend_2_18_5"
    images."penpotapp_backend_2_18_5"
    images."penpotapp_exporter_2_18_5"
    images."postgres_17_9-alpine"
    images."valkey_valkey_9_1-alpine"
  ];

  seedSrv = pkgs.runCommand "srv-seed-penpot" { } ''
    mkdir -p $out/stacks/penpot
    cp -r ${../../stacks/penpot}/. $out/stacks/penpot/
    chmod -R u+w $out/stacks/penpot
    # A locally-decrypted plaintext .env is gitignored but would still be
    # captured by cp -r into the world-readable store.
    rm -f $out/stacks/penpot/.env
    rm -f $out/stacks/penpot/secrets.example.env $out/stacks/penpot/secrets.sops.json
    ln -s /run/stack-env/penpot.env $out/stacks/penpot/.env
  '';

  stackMntRoots = [
    "/mnt/fast/penpot/assets"
    "/mnt/fast/penpot/pgdata"
  ];
  stackDirRules = (import ../../nixos/stack-dirs.nix).systemd.tmpfiles.rules;
  rulePath = r: lib.elemAt (lib.splitString " " r) 1;
  covers = dir: p: p == dir || lib.hasPrefix (dir + "/") p;
  missingRoots = lib.filter (root: !(lib.any (r: rulePath r == root) stackDirRules)) stackMntRoots;
  mntRules =
    if missingRoots == [ ] then
      lib.filter (r: lib.any (covers (rulePath r)) stackMntRoots) stackDirRules
    else
      throw (
        "penpot suite: nixos/stack-dirs.nix has no rule for "
        + lib.concatStringsSep ", " missingRoots
        + " — add the STACK_NOTES/DIR_NOTES entries and re-run nixos/generate-stack-dirs.sh"
      );
in
pkgs.testers.runNixOSTest {
  name = "penpot";

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
          # The same size its stackChecks entry needs (../default.nix).
          (profiles.sized {
            memoryMB = 6144;
            diskMB = 20480;
          })
          (profiles.loadImages {
            inherit pkgs;
            images = stackImages;
            beforeUnits = [ "multi-user.target" ];
          })
        ];

        systemd.services.bootstrap-komodo.wantedBy = lib.mkForce [ ];
        # Komodo's sync bootstrap Requires the masked unit and would pull it
        # back in; Forgejo runs from the host too, and only the forgejo and
        # gitops suites load its image.
        systemd.services.komodo-sync-bootstrap.wantedBy = lib.mkForce [ ];
        systemd.services.forgejo.wantedBy = lib.mkForce [ ];

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
          description = "Seed /srv with the penpot stack (test only)";
          after = [ "srv.mount" ];
          requires = [ "srv.mount" ];
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
    import json
    from urllib.parse import urlsplit, parse_qs

    P = "docker compose -f /srv/stacks/penpot/compose.yaml -p penpot"
    BASE = "http://127.0.0.1:10410"
    JSON = "-H 'Content-Type: application/json' -H 'Accept: application/json'"
    PSQL = "docker exec penpot_db psql -U penpot -d penpot -tAc"

    def dump_diag():
        for label, cmd in [
            ("compose ps", f"{P} ps -a"),
            ("backend logs", "docker logs penpot_backend 2>&1 | tail -60"),
            ("frontend logs", "docker logs penpot 2>&1 | tail -30"),
            ("exporter logs", "docker logs penpot_exporter 2>&1 | tail -20"),
            ("db logs", "docker logs penpot_db 2>&1 | tail -20"),
            ("stack-env-publish journal",
             "journalctl -u stack-env-publish --no-pager -o cat | tail -20"),
            ("data dirs", "ls -la /mnt/fast/penpot /mnt/fast/penpot/assets 2>&1"),
            ("disk", "df -h / /var/lib/docker 2>&1"),
        ]:
            print(f"--- {label} ---")
            print(services_vm.execute(cmd)[1])

    start_all()

    # 600s: the production NIC name (ens18) is absent here and its device job
    # times out at ~300s before multi-user settles.
    services_vm.wait_for_unit("multi-user.target", timeout=600)
    services_vm.wait_for_unit("stack-env-publish.service")
    services_vm.wait_for_unit("docker-network-homelab.service")
    services_vm.wait_for_unit("load-test-images.service")

    try:
        with subtest("the env renders root-only, with env.nix's two built values"):
            mode = services_vm.succeed("stat -c '%a %U' /run/stack-env/penpot.env").strip()
            assert mode == "400 root", f"expected '400 root', got {mode!r}"
            services_vm.succeed(
                "grep -qx \"PENPOT_DATABASE_PASSWORD='test_penpot_pg_password_not_secret'\" "
                "/run/stack-env/penpot.env"
            )
            services_vm.succeed(
                "grep -qx \"PENPOT_OIDC_CLIENT_SECRET='test_penpot_oidc_secret_not_secret'\" "
                "/run/stack-env/penpot.env"
            )

        with subtest("🚨 the stack comes up healthy, fully OFFLINE"):
            # No route out of this VM: --wait reaching healthy proves the
            # backend migrated without discovery or a JWKS fetch, and the
            # air-gapped frontend nginx started with no public DNS.
            services_vm.succeed(f"{P} up -d --wait --wait-timeout 600")
            services_vm.succeed(f"curl -fsS --max-time 10 {BASE}/readyz | grep -qx OK")

        with subtest("migrations applied to Postgres 17"):
            n = int(services_vm.succeed(f"{PSQL} 'select count(*) from migrations'").strip())
            assert n > 0, "the migrations table is empty"

        with subtest("config.js carries the flags and the SSO label"):
            cfg = services_vm.succeed(f"curl -fsS --max-time 10 {BASE}/js/config.js")
            for want in ("enable-login-with-oidc", "disable-login-with-password",
                         "disable-registration", "enable-oidc-registration",
                         'penpotOIDCName = "Authentik"',
                         'penpotPublicURI = "https://penpot.svc.idanreed.com"'):
                assert want in cfg, f"{want!r} missing from config.js:\n{cfg}"

        with subtest("🚨 the SSO login is Authentik's, with the blueprint's exact redirect URI"):
            body = services_vm.succeed(
                f"curl -fsS --max-time 30 {JSON} -X POST -d '{{\"provider\":\"oidc\"}}' "
                f"{BASE}/api/auth/oidc"
            )
            resp = json.loads(body)
            loc = resp.get("redirectUri") or resp.get("redirect-uri") or resp.get("redirect_uri")
            assert loc, f"no redirect URI in {body!r}"
            u = urlsplit(loc)
            q = parse_qs(u.query)
            assert (u.scheme, u.netloc, u.path) == ("https", "auth.idanreed.com", "/application/o/authorize/"), loc
            assert q.get("client_id") == ["penpot"], q
            assert q.get("redirect_uri") == ["https://penpot.svc.idanreed.com/api/auth/oidc/callback"], q
            assert q.get("response_type") == ["code"], q
            assert set(q["scope"][0].split()) >= {"openid", "email", "profile"}, q
            assert q.get("state"), q

        with subtest("🚨 password login and password registration are refused"):
            out = services_vm.execute(
                f"curl -sS --max-time 30 {JSON} -X POST "
                "-d '{\"email\":\"idan@idanreed.com\",\"password\":\"hunter22hunter22\"}' "
                f"{BASE}/api/rpc/command/login-with-password"
            )[1]
            assert "login-disabled" in out, f"password login answered: {out}"
            out = services_vm.execute(
                f"curl -sS --max-time 30 {JSON} -X POST "
                "-d '{\"fullname\":\"Intruder\",\"email\":\"intruder@example.com\","
                "\"password\":\"hunter22hunter22\"}' "
                f"{BASE}/api/rpc/command/prepare-register-profile"
            )[1]
            assert "registration-disabled" in out, f"registration answered: {out}"
            profiles = services_vm.succeed(f"{PSQL} 'select count(*) from profile'").strip()
            assert profiles == "0", f"{profiles} profile(s) exist after the refused attempts"

        with subtest("the exporter reaches the frontend by its service name"):
            services_vm.succeed(
                "docker exec penpot_exporter curl -fsS -o /dev/null --max-time 10 "
                "http://penpot-frontend:8080/"
            )

        with subtest("assets: 1001-owned, writable by the backend, read-only to the frontend"):
            owner = services_vm.succeed("stat -c %u:%g /mnt/fast/penpot/assets").strip()
            assert owner == "1001:1001", f"assets owned by {owner}"
            services_vm.succeed(
                "docker exec penpot_backend sh -c "
                "'touch /opt/data/assets/.suite-probe && rm /opt/data/assets/.suite-probe'"
            )
            services_vm.succeed(
                "docker exec penpot bash -c "
                "'test -d /opt/data/assets && ! touch /opt/data/assets/.suite-probe 2>/dev/null'"
            )

        with subtest("pg_dumpall runs as backup-prepare.sh runs it"):
            services_vm.succeed(
                "docker exec penpot_db pg_dumpall -U penpot | grep '^CREATE DATABASE penpot ' >/dev/null"
            )
            services_vm.succeed("test -f /mnt/fast/penpot/pgdata/PG_VERSION")

        with subtest("🚨 10410 is unreachable from another machine"):
            ip = services_vm.succeed(
                "ip -4 -o addr show eth1 | awk '{print $4}' | cut -d/ -f1"
            ).strip()
            outsider.wait_for_unit("network.target")
            outsider.succeed(f"ping -c1 -W5 {ip} >/dev/null")
            outsider.fail(f"curl -s --max-time 10 http://{ip}:10410/ >/dev/null")

        with subtest("everything still healthy at the end"):
            for name in ("penpot", "penpot_backend", "penpot_exporter", "penpot_db", "penpot_valkey"):
                services_vm.succeed(
                    "test \"$(docker inspect -f '{{.State.Health.Status}}' "
                    + name + ")\" = healthy"
                )
    except Exception:
        dump_diag()
        raise
  '';
}
