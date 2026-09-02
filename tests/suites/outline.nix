# Outline suite: everything about this stack that is provable OFFLINE.
#
# Outline has NO local accounts (no admin bootstrap, no CLI user-create) —
# Authentik OIDC IS the login, and the IdP is deliberately kept out of the
# boot path (manual OIDC_* endpoints in compose.yaml). Finding #65: 1.9.2
# boots, migrates, serves and reports healthy with an unreachable issuer, so
# a healthy container proves nothing about the login. What IS provable here:
#
#   - the OIDC redirect leg is generated LOCALLY: GET /auth/oidc 302s to
#     OIDC_AUTH_URI with client_id/redirect_uri/scope built from compose
#     values — the runtime half of the oidc-contract lint, and it fires on a
#     URL typo the lint cannot see (the lint compares two files that a single
#     edit keeps consistent);
#   - migrations really ran (the healthcheck's 180s start_period exists for
#     them, but `_health: OK` does not imply schema);
#   - zero users — pinning "first login creates the team and OWNS it";
#   - the uid-1001 upload path (compose: "finding #14 with the crash-loop
#     replaced by silence" — a root-owned data dir fails uploads at runtime
#     with no startup symptom, and this probe is the only automated view);
#   - the backup contract (`docker exec outline_db pg_dumpall -U outline`,
#     container_name and POSTGRES_USER both load-bearing);
#   - redis really is stateless (no mounts, RDB off).
#
# Deliberately NOT covered:
#   - logging in (needs a live Authentik + a browser; gatus's path probe is
#     the only automated signal, and it only proves the redirect);
#   - port exposure from off-host — stackChecks.outline (the generic suite)
#     keeps that leg, so this suite runs single-node.

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
    images."outlinewiki_outline_1_9_2"
    images."postgres_17_9-alpine"
    images."redis_7_4-alpine"
  ];

  seedSrv = pkgs.runCommand "srv-seed-outline" { } ''
    mkdir -p $out/stacks/outline
    cp -r ${../../stacks/outline}/. $out/stacks/outline/
    chmod -R u+w $out/stacks/outline
    rm -f $out/stacks/outline/.env
    rm -f $out/stacks/outline/.sops.env.example
    cp ${../fixtures/outline.sops.env} $out/stacks/outline/.sops.env
  '';

  # The REAL ownership rows for this stack (data is 1001:1001 — the uid-1001
  # trap above), from the same generated file production imports.
  stackDirRules = lib.filter (r: lib.hasInfix "/mnt/fast/outline" r) (
    (import ../../nixos/stack-dirs.nix).systemd.tmpfiles.rules
  );
in
pkgs.testers.runNixOSTest {
  name = "outline";

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

        systemd.services.bootstrap-komodo.wantedBy = lib.mkForce [ ];
        # stack-git-sync would fail its clone every tick with no Forgejo here.
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

        systemd.tmpfiles.rules = [
          "d /srv/stacks 0755 1000 1000 -"
          "d /var/lib/sops-nix 0700 root root -"
          "d /mnt/fast 0755 root root -"
          "d /mnt/slow 0755 root root -"
        ]
        ++ stackDirRules;

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
  };

  testScript = ''
    import json
    from urllib.parse import urlsplit, parse_qs

    OUTLINE = "docker compose -f /srv/stacks/outline/compose.yaml -p outline"
    BASE = "http://127.0.0.1:10203"

    def diag(label):
        print("=== diagnostics: " + label + " ===")
        for cmd in [
            "docker ps -a",
            "docker logs outline 2>&1 | tail -60",
            "docker logs outline_db 2>&1 | tail -20",
            "ls -la /mnt/fast/outline /mnt/fast/outline/data 2>&1",
            "df -h /var/lib/docker /mnt; free -m",
        ]:
            print("--- " + cmd)
            print(services_vm.execute(cmd)[1])

    def status(path, method="GET"):
        return int(services_vm.succeed(
            "curl -s -o /dev/null -w '%{http_code}' --max-redirs 0 "
            f"--max-time 30 -X {method} {BASE}{path}"
        ).strip())

    def sql(q):
        return services_vm.succeed(
            f"docker exec outline_db psql -U outline -d outline -tAc \"{q}\""
        ).strip()

    start_all()

    with subtest("decrypt-sops-envs produced a 0600 .env owned by uid 1000"):
        services_vm.wait_for_unit("multi-user.target")
        services_vm.wait_for_unit("docker-network-homelab.service")
        services_vm.wait_until_succeeds("test -s /srv/stacks/outline/.env", timeout=120)
        stat = services_vm.succeed("stat -c '%a %u:%g' /srv/stacks/outline/.env").strip()
        assert stat == "600 1000:1000", f".env is {stat}"
        for k in ["SECRET_KEY", "UTILS_SECRET", "POSTGRES_PASSWORD",
                  "DATABASE_URL", "OIDC_CLIENT_SECRET"]:
            services_vm.succeed(f"grep -q '^{k}=.' /srv/stacks/outline/.env")

    services_vm.wait_for_unit("load-test-images.service")

    with subtest("compose up brings app, db and redis healthy"):
        try:
            # 180s start_period covers cold-DB migrations; 900 is generous
            # for the 2-core VM.
            services_vm.succeed(f"{OUTLINE} up -d --wait --wait-timeout 900")
        except Exception:
            diag("compose up failed")
            raise

    with subtest("the OIDC redirect leg is built from the compose contract"):
        # /auth/oidc 302s to OIDC_AUTH_URI with parameters Outline composes
        # LOCALLY (no Authentik contact): the runtime proof that URL and the
        # blueprint's redirect_uri agree. Parsed properly rather than
        # substring-matched so percent-encoding case cannot flake it.
        redirect = services_vm.succeed(
            "curl -s -o /dev/null -w '%{redirect_url}' --max-redirs 0 "
            f"--max-time 30 {BASE}/auth/oidc"
        ).strip()
        assert redirect, "/auth/oidc did not redirect at all"
        parts = urlsplit(redirect)
        assert redirect.startswith("https://auth.idanreed.com/application/o/authorize/"), (
            f"redirect goes to {redirect!r}, not the Authentik authorize endpoint"
        )
        q = parse_qs(parts.query)
        assert q.get("client_id") == ["outline"], f"client_id: {q.get('client_id')}"
        assert q.get("redirect_uri") == ["https://outline.svc.idanreed.com/auth/oidc.callback"], (
            f"redirect_uri: {q.get('redirect_uri')} — URL in compose.yaml and the "
            "blueprint's redirect_uri must agree byte for byte"
        )
        assert q.get("scope") == ["openid profile email"], f"scope: {q.get('scope')}"
        assert q.get("state", [""])[0], "no state parameter in the authorize URL"

    with subtest("migrations really ran and the team is UNOWNED (zero users)"):
        n_migrations = int(sql("select count(*) from \\\"SequelizeMeta\\\""))
        assert n_migrations > 0, "SequelizeMeta is empty — migrations did not run"
        for t in ["users", "teams", "documents", "authentication_providers"]:
            reg = sql(f"select to_regclass('public.{t}')")
            assert reg == t, f"table {t} missing (to_regclass: {reg!r})"
        # 🚨 First login creates the team and owns it (compose header). Zero
        # users is the pinned pre-first-login state; if a seed path ever
        # appears upstream this catches it.
        n_users = int(sql("select count(*) from users"))
        assert n_users == 0, f"expected zero users before any login, found {n_users}"

    with subtest("uid-1001 writes into the data volume (the silent-upload trap)"):
        uid = services_vm.succeed("docker exec outline id -u").strip()
        assert uid == "1001", f"outline runs as uid {uid}, compose contract says 1001"
        # A root-owned data dir fails uploads at runtime with no startup
        # symptom; this probe is the only automated view of that path.
        services_vm.succeed(
            "docker exec outline touch /var/lib/outline/data/.phase2-probe"
        )
        services_vm.succeed(
            "docker exec outline rm /var/lib/outline/data/.phase2-probe"
        )

    with subtest("the backup contract: pg_dumpall -U outline against outline_db"):
        # Exactly the command nixos/backup-prepare.sh runs; container_name
        # and POSTGRES_USER are both load-bearing.
        services_vm.succeed(
            "docker exec outline_db pg_dumpall -U outline | grep -q 'CREATE ROLE'"
        )

    with subtest("redis is stateless: no mounts, RDB snapshots off"):
        mounts = json.loads(services_vm.succeed(
            "docker inspect outline_redis --format '{{json .Mounts}}'"
        ))
        assert not mounts, f"outline_redis has mounts: {mounts!r}"
        save = services_vm.succeed(
            "docker exec outline_redis redis-cli config get save"
        ).strip().splitlines()
        assert save and save[-1] == "", f"redis save config: {save!r} (RDB not disabled)"

    with subtest("no session means 401, and plain http / means the 301 measured"):
        # No way in but OIDC — asserted, not assumed.
        code = status("/api/auth.info", method="POST")
        assert code == 401, f"unauthenticated /api/auth.info answered {code}"
        # FORCE_HTTPS stays default: `/` 301s on plain http while /_health
        # (the healthcheck, already green above) answers regardless —
        # the measured pair from the compose header.
        code = status("/")
        assert code == 301, f"plain-http / answered {code}, expected the measured 301"
  '';
}
