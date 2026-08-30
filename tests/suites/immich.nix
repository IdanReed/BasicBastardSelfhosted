# Immich suite (heavy): the photo stack on the services VM — immich-server,
# machine-learning, postgres (VectorChord), valkey, plus the two oneshots
# (immich-config-init, immich-init). Hand-written because mk-stack-suite's
# generic all-containers-running assertion cannot pass a stack with
# restart:"no" oneshots (its header says so). Annex §6 of
# ServerNotes/designs/service-immich-stack-research.md is the assertion spec.
#
# Genuinely under test:
#   - decrypt-sops-envs turning stacks/immich/.sops.env into a 0600 .env owned
#     1000:1000, and env threading END TO END: the DB password, the OIDC
#     client secret and the admin credentials exist only in the encrypted
#     fixture, so a working login + a rendered immich.json carrying the
#     fixture secret prove the whole sops -> .env -> env_file chain
#   - immich-config-init's MAKE-STYLE render contract (annex §3 rotation
#     coupling): renders exactly the template with ONLY the secret
#     substituted, 0600, no-op on re-run, REWRITES on a rotated secret
#     (tmpfile+rename — unlike qbit-init's touch-once), and restores when the
#     secret rotates back
#   - the full first boot: schema migrations + vchord/vector extension
#     creation inside the healthcheck budget, admin seeded headlessly
#     (POST /api/auth/admin-sign-up), idempotent under Arcane redeploys
#   - the v3 API shapes the annex warns about (§0.4/§0.7): multipart upload
#     with assetData/fileCreatedAt/fileModifiedAt only (no deviceId), API
#     keys minted with a `permissions` array
#   - thumbnails WITHOUT ML: generation is a server-side job (sharp/ffmpeg),
#     pinned here so an upstream re-architecture that moves it into the ML
#     container fails a test
#   - the ML degrade contract: "healthy" for the ML container means ITS OWN
#     HTTP server answers (/ping probed from the compose network) — model
#     presence is NOT part of health; a smart search errors without taking
#     the server down
#   - loopback-only publishing for 10102 and the §2 "must NOT publish" list
#     (ml :3003 is an unauthenticated inference API, postgres :5432,
#     valkey :6379) — asserted from another host AND via docker port
#   - the backup contract backup-prepare.sh hardcodes: container immich_db,
#     pg_dumpall -U immich, and the dump actually containing the database
#   - reboot survival on PERSISTENT storage: /mnt lives on a real ext4 disk
#     in this suite (not tmpfs like the media suite) precisely so the reboot
#     subtest asserts data durability — pgdata, the photo tree and the
#     rendered config must all come back and the uploaded asset stay
#     retrievable
#
# Documented egress gaps (a green run covers NONE of these — annex §6):
#   - ML model download and every inference RESULT: smart-search hits, facial
#     recognition, duplicate detection, OCR. Offline the models can never
#     arrive from Hugging Face; the accepted state is healthy ML + failing
#     inference jobs, and that is exactly what is asserted.
#   - the live OIDC browser flow (redirect -> Authentik -> callback) and the
#     mobile app.immich:///oauth-callback handoff — doubly uncoverable since
#     v3 requires secure (https) requests for OAuth (annex §0.6) and the
#     suite speaks plain HTTP on loopback. Only the offline config contract
#     is asserted (features flags, issuer/clientId/secret in immich.json).
#   - map tiles and Immich's new-version check (both dial out).
#   - the built-in daily DB dump firing at its real 02:00 cron — only the
#     host-side pg_dumpall path is exercised here.

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
    # The boot chain: bootstrap-arcane is wantedBy multi-user.target, so its
    # image must be loadable before the script gets control.
    images."ghcr_io_getarcaneapp_arcane_v1_17_4"
    # The stack, every pinned ref from stacks/immich/compose.yaml:
    images."ghcr_io_immich-app_immich-server_v3_1_0"
    images."ghcr_io_immich-app_immich-machine-learning_v3_1_0"
    images."ghcr_io_immich-app_postgres_17-vectorchord1_1_1"
    images."valkey_valkey_9_1-alpine"
    images."alpine_3_21" # immich-config-init
    images."python_3_13-alpine" # immich-init (+ the suite's ML /ping probe)
  ];

  # Seeds /srv the way the real host gets it: Arcane's git sync on the live
  # machine, a store copy here. Only the immich stack is seeded — the other
  # stacks are the light suite's job — plus /srv/arcane for bootstrap-arcane.
  seedSrv = pkgs.runCommand "srv-seed-immich" { } ''
    mkdir -p $out/arcane $out/stacks/immich
    cp ${../../arcane/compose.yaml} $out/arcane/compose.yaml
    cp ${../fixtures/arcane.sops.env} $out/arcane/.sops.env

    cp -r ${../../stacks/immich}/. $out/stacks/immich/
    chmod -R u+w $out/stacks/immich
    # The working-tree cp -r can capture a developer's locally-decrypted
    # plaintext .env (gitignored on purpose) in the world-readable store.
    rm -f $out/stacks/immich/.env
    rm -f $out/stacks/immich/.sops.env.example
    cp ${../fixtures/immich.sops.env} $out/stacks/immich/.sops.env
  '';
in
pkgs.testers.runNixOSTest {
  name = "immich";

  # First boot runs the full schema migration + extension creation, thumbnail
  # jobs are polled with minutes-scale budgets, and there is a reboot. The
  # driver's 3600s default would kill the VMs without running any except
  # handler, so the diag dumps would never print.
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
          # No headscale in this suite; left on boot it would retry forever
          # against an unreachable login server and hold up multi-user.target.
          profiles.manualTailscaleAutoconnect
          (profiles.sopsFixture ../fixtures/services-vm.sops.yaml)
          # immich-server (node) + ML (torch/onnx resident) + postgres all
          # want real memory, and four multi-GB unpacked images live in
          # /var/lib/docker on the root disk.
          (profiles.sized {
            memoryMB = 8192;
            diskMB = 24576;
          })
          (profiles.loadImages {
            inherit pkgs;
            images = stackImages;
            beforeUnits = [ "bootstrap-arcane.service" ];
          })
        ];

        # Migrations + thumbnail jobs + ML import on the sized profile's 2
        # cores make every healthcheck window a coin toss; 4 keeps it sane.
        virtualisation.cores = lib.mkForce 4;

        # decrypt-sops-envs.service and bootstrap-arcane.service both
        # `requires = srv.mount`; the tmpfs gives them a genuine .mount unit.
        # /srv stays tmpfs ON PURPOSE: its post-reboot re-seed + re-decrypt is
        # itself the production shape (Arcane sync + the decrypt timer).
        #
        # /mnt is DIFFERENT from the media suite: a real ext4 on a persistent
        # qcow (auto-formatted on first boot only), because the reboot subtest
        # asserts DATA DURABILITY — pgdata, the photo originals and the
        # rendered immich.json must survive, which tmpfs cannot represent.
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
          # Mirrors nixos/hardware-configuration.nix, which cannot be
          # imported here because it mounts real partitions by partlabel.
          "d /srv/arcane 0755 root root -"
          "d /srv/stacks 0755 1000 1000 -"
          "d /var/lib/sops-nix 0700 root root -"
          # The /mnt disk is bare ext4; production's separate fast/slow
          # mountpoints are plain directories here.
          "d /mnt/fast 0755 root root -"
          "d /mnt/slow 0755 root root -"
          # Immich bind-mount roots — the SAME set production declares in
          # hardware-configuration.nix; keep the two lists in sync by hand.
          # root:root ON PURPOSE: the immich images have no PUID/PGID and run
          # as root (annex §2/§7.5 — non-root mode deliberately not used),
          # postgres chowns pgdata itself, and config-init writes the 0600
          # immich.json as root. The seerr uid-1000 class (finding #14) does
          # not apply.
          "d /mnt/fast/immich 0755 root root -"
          "d /mnt/fast/immich/pgdata 0755 root root -"
          "d /mnt/fast/immich/model-cache 0755 root root -"
          "d /mnt/fast/immich/config 0755 root root -"
          "d /mnt/slow/photos 0755 root root -"
        ];

        # Populate /srv before anything reads it — the stand-in for Arcane's
        # git sync having already run. Re-runs on every boot (tmpfs /srv),
        # which the reboot subtest depends on.
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
            mkdir -p /srv/arcane /srv/stacks
            cp -r --no-preserve=mode ${seedSrv}/arcane/. /srv/arcane/
            cp -r --no-preserve=mode ${seedSrv}/stacks/. /srv/stacks/
            chown -R 1000:1000 /srv/stacks
          '';
        };

        environment.systemPackages = with pkgs; [
          docker-compose
          jq
        ];
      };

    # Another host on the LAN, for the negative binding assertions: anything
    # it can reach on a non-tailnet interface is reachable from the whole
    # VLAN — and the immich API serves every original photo.
    outsider = { };
  };

  testScript = ''
    import json
    import re
    import shlex

    IMMICH = "docker compose -f /srv/stacks/immich/compose.yaml -p immich"
    BASE = "http://127.0.0.1:10102"

    # Fixture values from tests/fixtures/immich.sops.env — committed test-only
    # secrets (see the fixture header; stack-env-drift keeps the key set
    # honest against the real .sops.env).
    ADMIN_EMAIL = "admin@test.invalid"
    ADMIN_PASS = "test_immich_admin_password_not_secret"
    OIDC_SECRET = "test_immich_oidc_client_secret_not_secret"
    ROTATED_SECRET = "test_rotated_oidc_secret_not_secret"

    CONF = "/mnt/fast/immich/config/immich.json"

    def diag(label):
        # A --wait failure minutes into first-boot migrations is useless
        # without context; dump what docker actually did on the way out.
        print("=== diagnostics: " + label + " ===")
        for cmd in [
            "docker ps -a",
            "docker logs immich_server 2>&1 | tail -60",
            "docker logs immich_db 2>&1 | tail -30",
            "docker logs immich_machine_learning 2>&1 | tail -30",
            "docker logs immich_redis 2>&1 | tail -10",
            "docker logs immich_config_init 2>&1 | tail -20",
            "docker logs immich_init 2>&1 | tail -20",
            "ls -la /srv/stacks/immich /mnt/fast/immich "
            "/mnt/fast/immich/config /mnt/slow/photos 2>&1",
            "cat /mnt/fast/immich/config/immich.json 2>&1",
            "df -h /var/lib/docker /mnt; free -m",
        ]:
            print("--- " + cmd)
            print(services_vm.execute(cmd)[1])

    def api(path, method="GET", body=None, key=None, bearer=None):
        # Immich API helper: JSON in/out against the loopback publish. Bodies
        # go through a pipe so shell quoting cannot mangle them.
        cmd = f"curl -sf --max-time 60 -X {method} "
        if key:
            cmd += f"-H 'x-api-key: {key}' "
        if bearer:
            cmd += f"-H 'Authorization: Bearer {bearer}' "
        cmd += "-H 'Content-Type: application/json' "
        if body is not None:
            payload = shlex.quote(json.dumps(body))
            cmd = f"printf '%s' {payload} | " + cmd + "-d @- "
        out = services_vm.succeed(cmd + BASE + "/api/" + path)
        return json.loads(out) if out.strip() else None

    start_all()

    # -----------------------------------------------------------------------
    # §6.1 boot chain + decrypt: sops fixture -> 0600 .env owned 1000:1000
    # -----------------------------------------------------------------------
    with subtest("decrypt-sops-envs produced a 0600 .env owned by arcane's uid"):
        services_vm.wait_for_unit("docker-network-homelab.service")
        services_vm.wait_for_unit("bootstrap-arcane.service")
        services_vm.succeed("test -s /srv/stacks/immich/.env")
        stat = services_vm.succeed(
            "stat -c '%a %u:%g' /srv/stacks/immich/.env"
        ).strip()
        assert stat == "600 1000:1000", f".env is {stat}, expected 600 1000:1000"
        # The keys everything below depends on: a later failure then points
        # at the service, not at decryption.
        for k in ["DB_PASSWORD", "POSTGRES_PASSWORD",
                  "IMMICH_OIDC_CLIENT_SECRET", "IMMICH_ADMIN_EMAIL"]:
            services_vm.succeed(f"grep -q '^{k}=' /srv/stacks/immich/.env")

    # Images are loaded before bootstrap-arcane; the compose runs below must
    # not race the load (an `up` mid-load pulls nothing offline).
    services_vm.wait_for_unit("load-test-images.service")

    # -----------------------------------------------------------------------
    # §6.2 config render: template + secret -> /config/immich.json
    # -----------------------------------------------------------------------
    with subtest("immich-config-init renders immich.json (0600, valid, exact)"):
        try:
            services_vm.succeed(IMMICH + " up -d immich-config-init")
            services_vm.wait_until_succeeds(
                "docker inspect -f '{{.State.Status}}/{{.State.ExitCode}}' "
                "immich_config_init | grep -qx exited/0",
                timeout=120,
            )
        except Exception:
            diag("config-init run")
            raise
        mode = services_vm.succeed(f"stat -c '%a' {CONF}").strip()
        assert mode == "600", f"immich.json is mode {mode}, expected 600"
        # Valid JSON carrying the fixture secret — proves sops -> .env ->
        # render end to end (the secret exists only in the encrypted fixture).
        secret = services_vm.succeed(
            f"jq -r .oauth.clientSecret {CONF}"
        ).strip()
        assert secret == OIDC_SECRET, f"rendered clientSecret: {secret!r}"
        # Rendered-minus-secret must equal the template byte for byte: guards
        # the init drifting into templating more than the one placeholder.
        services_vm.succeed(
            f"sed 's/{OIDC_SECRET}/__IMMICH_OIDC_CLIENT_SECRET__/' {CONF} "
            "| cmp - /srv/stacks/immich/immich.json.template"
        )

    # -----------------------------------------------------------------------
    # §6.3 the stack comes up (first boot: migrations + extension creation)
    # -----------------------------------------------------------------------
    with subtest("docker compose brings up server, ml, db and valkey healthy"):
        # immich-init is NOT in the --wait set: compose's --wait reports
        # failure for an in-scope oneshot that exited 0 unless a dependent
        # consumes it — immich-config-init has one (the server), immich-init
        # has none. Same trap the media suite documents.
        try:
            services_vm.succeed(
                IMMICH + " up -d --wait --wait-timeout 900 "
                "immich-server immich-machine-learning database redis",
                timeout=1000,
            )
        except Exception:
            diag("compose up --wait")
            raise

    with subtest("immich-init seeds the admin and exits 0"):
        try:
            services_vm.succeed(IMMICH + " up -d immich-init")
            services_vm.wait_until_succeeds(
                "docker inspect -f '{{.State.Status}}/{{.State.ExitCode}}' "
                "immich_init | grep -qx exited/0",
                timeout=180,
            )
        except Exception:
            diag("immich-init run")
            raise
        # First run against a fresh DB is THE mutation — it must say so
        # (media-init's CHANGE: contract).
        seed_log = services_vm.succeed("docker logs immich_init 2>&1")
        assert "immich-init: CHANGE: admin" in seed_log, (
            f"first immich-init run logged no CHANGE line:\n{seed_log}"
        )

    with subtest("every container is in its contract state"):
        # ML "healthy" here means ITS OWN HTTP server answers (the image's
        # builtin healthcheck) — models can never arrive offline and are NOT
        # part of health, by design (annex §6 preamble).
        for name in ["immich_server", "immich_machine_learning",
                     "immich_db", "immich_redis"]:
            h = services_vm.succeed(
                f"docker inspect -f '{{{{.State.Health.Status}}}}' {name}"
            ).strip()
            assert h == "healthy", f"{name} is {h!r}, expected healthy"
        for name in ["immich_config_init", "immich_init"]:
            code = services_vm.succeed(
                f"docker inspect -f '{{{{.State.ExitCode}}}}' {name}"
            ).strip()
            assert code == "0", f"{name} exited {code}, expected 0"
        # And concretely: the modelless ML answers /ping on the compose
        # network (probed from a sibling container — :3003 is unpublished).
        services_vm.succeed(
            "docker run --rm --network immich_default python:3.13-alpine "
            "python3 -c " + shlex.quote(
                "import urllib.request; "
                "assert urllib.request.urlopen("
                "'http://immich-machine-learning:3003/ping', timeout=10"
                ").status == 200"
            )
        )

    # -----------------------------------------------------------------------
    # §6.4 version endpoint == the compose pin (image-bump drift guard)
    # -----------------------------------------------------------------------
    with subtest("/api/server/version equals the compose pin"):
        services_vm.succeed(
            f"curl -sf --max-time 10 {BASE}/api/server/ping "
            "| jq -e '.res == \"pong\"'"
        )
        compose = services_vm.succeed("cat /srv/stacks/immich/compose.yaml")
        m = re.search(r"immich-server:v(\d+)\.(\d+)\.(\d+)", compose)
        assert m, "no immich-server pin found in compose.yaml"
        pin_ver = tuple(int(x) for x in m.groups())
        ver = json.loads(services_vm.succeed(
            f"curl -sf --max-time 10 {BASE}/api/server/version"
        ))
        live_ver = (ver["major"], ver["minor"], ver["patch"])
        assert live_ver == pin_ver, (
            f"server reports {live_ver}, compose pins {pin_ver}"
        )

    # -----------------------------------------------------------------------
    # §6.5 admin seed: fixture credentials log in; re-run is a no-op
    # -----------------------------------------------------------------------
    with subtest("the seeded admin logs in with the fixture credentials"):
        login = api("auth/login", "POST",
                    {"email": ADMIN_EMAIL, "password": ADMIN_PASS})
        token = login.get("accessToken")
        assert token, f"login returned no accessToken: {login!r}"
        assert login.get("isAdmin") is True, f"seeded user not admin: {login!r}"
        # Negative: a wrong password is refused (401), so the positive above
        # is not an auth-disabled fluke.
        code = services_vm.succeed(
            "printf '%s' " + shlex.quote(json.dumps(
                {"email": ADMIN_EMAIL, "password": "definitely-wrong"}))
            + " | curl -s -o /dev/null -w '%{http_code}' --max-time 10 "
            "-H 'Content-Type: application/json' -d @- "
            + BASE + "/api/auth/login"
        ).strip()
        assert code == "401", f"wrong-password login returned {code}"

    with subtest("immich-init is idempotent: a re-run logs zero CHANGE lines"):
        # Every Arcane redeploy re-runs the oneshot; "already onboarded" must
        # be success, not failure, and must not claim a change.
        out = services_vm.succeed("docker start -a immich_init 2>&1")
        assert "CHANGE:" not in out, f"second immich-init run mutated:\n{out}"
        assert "already onboarded" in out, (
            f"second run did not report already-onboarded:\n{out}"
        )

    # -----------------------------------------------------------------------
    # §6.6 API key mint — the v3 permission-scoped headless path
    # -----------------------------------------------------------------------
    with subtest("an api key with permissions:[all] mints and authenticates"):
        minted = api("api-keys", "POST",
                     {"name": "suite-key", "permissions": ["all"]},
                     bearer=token)
        apikey = minted.get("secret")
        assert apikey, f"api-key mint returned no secret: {minted!r}"
        me = api("users/me", key=apikey)
        assert me.get("email") == ADMIN_EMAIL, f"users/me via key: {me!r}"

    # -----------------------------------------------------------------------
    # §6.7 upload -> asset pipeline (v3 multipart shape, no deviceId)
    # -----------------------------------------------------------------------
    with subtest("a multipart upload lands and is listed"):
        # 1x1 PNG, fixed bytes; fields per annex §0.4 — deviceId/deviceAssetId
        # were REMOVED in v3.0.0, cargo-culting them must not be needed.
        png_b64 = ("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ"
                   "AAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")
        services_vm.succeed(
            f"echo '{png_b64}' | base64 -d > /tmp/immich-suite.png"
        )
        try:
            up = json.loads(services_vm.succeed(
                f"curl -sf --max-time 120 -H 'x-api-key: {apikey}' "
                "-F 'assetData=@/tmp/immich-suite.png;type=image/png' "
                "-F fileCreatedAt=2026-01-01T00:00:00.000Z "
                "-F fileModifiedAt=2026-01-01T00:00:00.000Z "
                + BASE + "/api/assets"
            ))
        except Exception:
            diag("asset upload")
            raise
        asset_id = up.get("id")
        assert asset_id, f"upload returned no id: {up!r}"
        asset = api(f"assets/{asset_id}", key=apikey)
        assert asset.get("type") == "IMAGE", f"asset type: {asset!r}"
        # Metadata search is non-ML — the offline-valid search positive.
        found = api("search/metadata", "POST", {}, key=apikey)
        ids = [a.get("id") for a in found.get("assets", {}).get("items", [])]
        assert asset_id in ids, f"metadata search missed the asset: {ids!r}"

    # -----------------------------------------------------------------------
    # §6.8 thumbnails WITHOUT ML (server-side sharp/ffmpeg job)
    # -----------------------------------------------------------------------
    with subtest("the thumbnail generates with no ML models available"):
        try:
            services_vm.wait_until_succeeds(
                f"curl -sf --max-time 10 -H 'x-api-key: {apikey}' "
                f"{BASE}/api/assets/{asset_id}/thumbnail -o /dev/null",
                timeout=300,
            )
            services_vm.wait_until_succeeds(
                f"curl -sf --max-time 10 -H 'x-api-key: {apikey}' "
                f"{BASE}/api/assets/{asset_id} "
                "| jq -e '.thumbhash != null'",
                timeout=300,
            )
        except Exception:
            diag("thumbnail generation")
            raise

    # -----------------------------------------------------------------------
    # §6.9 ML degrade contract: inference fails, the server does not
    # -----------------------------------------------------------------------
    with subtest("a smart search errors without killing the server"):
        # ML is up but modelless (and cannot download — no egress): the
        # request must fail as an ERROR RESPONSE, not a hang or a server
        # death. This is the accepted production state until first egress.
        code = services_vm.succeed(
            "printf '%s' " + shlex.quote(json.dumps({"query": "a cat"}))
            + f" | curl -s -o /dev/null -w '%{{http_code}}' --max-time 180 "
            f"-H 'x-api-key: {apikey}' -H 'Content-Type: application/json' "
            f"-d @- {BASE}/api/search/smart"
        ).strip()
        assert code not in ("200", "000"), (
            f"smart search returned {code} — expected an error status offline"
        )
        services_vm.succeed(
            f"curl -sf --max-time 10 {BASE}/api/server/ping -o /dev/null"
        )
        h = services_vm.succeed(
            "docker inspect -f '{{.State.Health.Status}}' immich_server"
        ).strip()
        assert h == "healthy", f"server is {h!r} after the failed smart search"

    # -----------------------------------------------------------------------
    # §6.10 OIDC config contract, offline
    # -----------------------------------------------------------------------
    with subtest("the server advertises oauth from the rendered config file"):
        feats = json.loads(services_vm.succeed(
            f"curl -sf --max-time 10 {BASE}/api/server/features"
        ))
        for flag in ["oauth", "configFile", "passwordLogin"]:
            assert feats.get(flag) is True, (
                f"features.{flag} is {feats.get(flag)!r}, expected true: {feats!r}"
            )
        conf = json.loads(services_vm.succeed(
            f"curl -sf --max-time 10 {BASE}/api/server/config"
        ))
        assert conf.get("oauthButtonText") == "Login with Authentik", (
            f"oauthButtonText: {conf.get('oauthButtonText')!r}"
        )
        # The rendered file carries the annex §3 identity (the oidc-contract
        # lint ties these same values to the Authentik blueprint).
        issuer = services_vm.succeed(f"jq -r .oauth.issuerUrl {CONF}").strip()
        assert issuer == "https://auth.idanreed.com/application/o/immich/", (
            f"issuerUrl: {issuer!r}"
        )
        cid = services_vm.succeed(f"jq -r .oauth.clientId {CONF}").strip()
        assert cid == "immich", f"clientId: {cid!r}"

    # -----------------------------------------------------------------------
    # config-init is MAKE-STYLE: rotation reaches the rendered file
    # -----------------------------------------------------------------------
    with subtest("config-init re-run is a no-op; a rotated secret re-renders"):
        # (annex §3 rotation coupling — the reason this is NOT qbit-init's
        # touch-once.) Only the rendered FILE is asserted here: the running
        # immich-server keeps its startup-loaded config, so pickup after a
        # rotation relies on the production re-up (compose header / annex §3)
        # — the server is deliberately not restarted in this subtest.
        # Re-run with the unchanged env: no change.
        out = services_vm.succeed("docker start -a immich_config_init 2>&1")
        assert "no change" in out and "CHANGE:" not in out, (
            f"unchanged re-run was not a no-op:\n{out}"
        )
        # A rotated secret (env override on a one-off run; `compose run`
        # ignores container_name so there is no name collision) MUST rewrite.
        out = services_vm.succeed(
            IMMICH + " run --rm "
            f"-e IMMICH_OIDC_CLIENT_SECRET={ROTATED_SECRET} "
            "immich-config-init 2>&1"
        )
        assert "CHANGE: rendered" in out, (
            f"rotated secret did not re-render immich.json:\n{out}"
        )
        cur = services_vm.succeed(f"jq -r .oauth.clientSecret {CONF}").strip()
        assert cur == ROTATED_SECRET, f"post-rotation clientSecret: {cur!r}"
        mode = services_vm.succeed(f"stat -c '%a' {CONF}").strip()
        assert mode == "600", f"re-rendered immich.json is mode {mode}"
        # Rotate back via the original container (its env is the fixture
        # .env): change again, then stable.
        out = services_vm.succeed("docker start -a immich_config_init 2>&1")
        assert "CHANGE: rendered" in out, (
            f"rotating back did not re-render:\n{out}"
        )
        cur = services_vm.succeed(f"jq -r .oauth.clientSecret {CONF}").strip()
        assert cur == OIDC_SECRET, f"restored clientSecret: {cur!r}"

    # -----------------------------------------------------------------------
    # §6.11 the vector extensions really exist (migrations created them)
    # -----------------------------------------------------------------------
    with subtest("postgres carries the vchord and vector extensions"):
        ext = services_vm.succeed(
            "docker exec immich_db psql -U immich -d immich -tAc "
            "'select extname from pg_extension'"
        ).split()
        for extname in ["vchord", "vector"]:
            assert extname in ext, f"extension {extname!r} missing: {ext!r}"

    # -----------------------------------------------------------------------
    # §6.14 backup contract: the exact names backup-prepare.sh hardcodes
    # -----------------------------------------------------------------------
    with subtest("backup-prepare's immich leg produces a real dump"):
        # The literal loop body from nixos/backup-prepare.sh (svc=immich):
        # container_name immich_db + POSTGRES_USER=immich are load-bearing —
        # rename either and the nightly dump silently stops matching.
        services_vm.succeed("install -d -m 0700 /mnt/fast/_dumps")
        services_vm.succeed(
            "docker exec immich_db pg_dumpall -U immich "
            "> /mnt/fast/_dumps/immich.sql.tmp "
            "&& mv -f /mnt/fast/_dumps/immich.sql.tmp /mnt/fast/_dumps/immich.sql"
        )
        services_vm.succeed("test -s /mnt/fast/_dumps/immich.sql")
        # Content, not just existence (media's test -f pattern, upgraded):
        # the immich database and the asset row that holds the upload.
        services_vm.succeed(
            "grep -q 'CREATE DATABASE immich' /mnt/fast/_dumps/immich.sql"
        )
        services_vm.succeed(
            f"grep -q {asset_id} /mnt/fast/_dumps/immich.sql"
        )

    # -----------------------------------------------------------------------
    # §6.12 + §6.13 publishing: loopback positive, VLAN + publish negatives
    # -----------------------------------------------------------------------
    with subtest("10102 answers on loopback"):
        services_vm.succeed(
            f"curl -sf --max-time 10 {BASE}/api/server/ping -o /dev/null"
        )

    with subtest("nothing immich is reachable from the VLAN; ml/db/valkey publish nowhere"):
        # Positive control: the outsider can reach the VM at all (22 is in
        # allowedTCPPorts); without it every fail() below would pass
        # identically on a dead vlan.
        outsider.succeed("nc -z -w 5 services-vm 22")
        for port in [10102, 3003, 5432, 6379]:
            outsider.fail(f"nc -z -w 5 services-vm {port}")
        # And the §2 "must NOT publish" list holds even on loopback: zero
        # host port mappings at all for the internal three.
        for name in ["immich_machine_learning", "immich_db", "immich_redis"]:
            ports = services_vm.succeed(f"docker port {name}").strip()
            assert ports == "", f"{name} publishes ports: {ports!r}"

    # -----------------------------------------------------------------------
    # §6.15 reboot survival: durability across the persistent /mnt disk
    # -----------------------------------------------------------------------
    with subtest("the stack returns after a reboot with the asset intact"):
        services_vm.shutdown()
        services_vm.start()
        services_vm.wait_for_unit("docker-network-homelab.service")
        services_vm.wait_for_unit("bootstrap-arcane.service")
        # restart:unless-stopped brings the four long-runners back; the
        # oneshots stay exited (restart:"no") — nothing re-seeds, which is
        # exactly why the data must have survived on disk.
        try:
            services_vm.wait_until_succeeds(
                f"curl -sf --max-time 10 {BASE}/api/server/ping -o /dev/null",
                timeout=600,
            )
            for name in ["immich_server", "immich_machine_learning",
                         "immich_db", "immich_redis"]:
                services_vm.wait_until_succeeds(
                    f"docker inspect -f '{{{{.State.Health.Status}}}}' {name} "
                    "| grep -qx healthy",
                    timeout=600,
                )
        except Exception:
            diag("post-reboot")
            raise
        # The API key (postgres), the asset row (postgres), the original and
        # its thumbnail (photo tree) and the rendered config all survived.
        asset = api(f"assets/{asset_id}", key=apikey)
        assert asset.get("type") == "IMAGE", f"post-reboot asset: {asset!r}"
        services_vm.succeed(
            f"curl -sf --max-time 10 -H 'x-api-key: {apikey}' "
            f"{BASE}/api/assets/{asset_id}/thumbnail -o /dev/null"
        )
        secret = services_vm.succeed(f"jq -r .oauth.clientSecret {CONF}").strip()
        assert secret == OIDC_SECRET, f"post-reboot clientSecret: {secret!r}"

    # -----------------------------------------------------------------------
    # Nothing failed that the suite did not fail on purpose
    # -----------------------------------------------------------------------
    with subtest("no unit is left failed at suite end"):
        # backup-prepare (02:45) and backup-staleness-check (12:00) are
        # wall-clock timers that legitimately fail on this fixture host (no
        # VPS key, no success stamp) if the suite straddles their OnCalendar
        # moment; their failure paths are the services suite's coverage.
        allowed = {"backup-prepare.service", "backup-staleness-check.service"}
        failed = services_vm.succeed(
            "systemctl --failed --no-legend --plain"
        ).strip()
        rogue = [l for l in failed.splitlines() if l.split()[0] not in allowed]
        assert not rogue, "failed units at suite end:\n" + "\n".join(rogue)
  '';
}
