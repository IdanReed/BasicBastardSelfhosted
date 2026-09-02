# The Komodo GitOps loop, for real, OFFLINE: push -> sync -> decrypt -> deploy
# -> update, driven end to end against a live Komodo Core + Periphery + FerretDB
# + Postgres, all loaded from the Nix store with no network. This is the
# invariant-#4 proof (air-gapped deploy plane) and the finding-#11 proof
# (deploy reads a .env Komodo never created).
#
# The chain, and who owns each link (the whole point of the migration is that
# the age key and the git credentials both stay OFF the socket-touching
# Periphery):
#   (a) a compose repo is pushed to the REAL Forgejo stack in the same VM.
#   (b) stack-git-sync (a HOST unit, not a container) pulls it over loopback
#       with a read-only Forgejo token and materialises
#       /srv/stacks/<name>/{compose.yaml,.sops.env} owned 1000:1000.
#   (c) decrypt-sops-envs (host) writes the sibling .env within a timer tick,
#       chowned 1000:1000 — the age key never leaves the host.
#   (d) Komodo Core registers a files_on_host Stack via its API and Periphery
#       (which dialled Core over the Noise keypair, no passkey) runs
#       `docker compose up` in that directory. The container comes up AND, via
#       env_file, SEES the host-decrypted secret — the loop closed on a value
#       that exists only encrypted. environment="" so Komodo writes no env file
#       of its own: the decrypted .env is never clobbered (the CLOBBER HAZARD).
#   (e) a second push + re-sync + redeploy reflects the change.
#
# Why the registration is driven by the API and not a Resource-Sync TOML:
# Komodo's RunSync only REGISTERS resources — deploy-on-sync is upstream-broken
# (issue #1120), so a deploy is always a separate explicit action (the API call
# here, or the Stack's /listener/github/stack/{id}/deploy webhook in
# production). Driving CreateStack + DeployStack directly is the deterministic
# form of exactly what the webhook triggers, and it does not need Core to hold
# git credentials for Forgejo. The git-declarative registration path is
# documented in ServerNotes/designs/komodo-migration.md.
#
# The v2 auth model is load-bearing here and DIFFERENT from the design's first
# draft: Core auto-creates an enabled server "Local" (KOMODO_FIRST_SERVER_NAME)
# and Periphery DIALS Core (ws://core:9120) authenticating with the Noise
# keypair in the shared /config/keys volume. The old shared KOMODO_PASSKEY is
# the deprecated v1 path and is gone. Verified against komodo 2.1.0: ListServers
# shows "Local" state Ok with no network.
#
# The API contract, verified against a live komodo 2.1.0:
#   login   POST /auth/login/LoginLocalUser {username,password} -> {data:{jwt}}
#   authed  POST /read|/write|/execute/<Type>  header `authorization: <jwt>`
#           (RAW jwt, no Bearer), body = the params object.

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
    images."ghcr_io_moghtech_komodo-core_2_1_0"
    images."ghcr_io_moghtech_komodo-periphery_2_1_0"
    images."ghcr_io_ferretdb_ferretdb_2_7_0"
    images."ghcr_io_ferretdb_postgres-documentdb_17-0_107_0-ferretdb-2_7_0"
    # The remote: the real forgejo stack, playing the production forge.
    images."codeberg_org_forgejo_forgejo_16_0"
    # The test project's container image; pinned and preloaded like all others.
    images."alpine_3_21"
  ];

  seedSrv = pkgs.runCommand "srv-seed-gitops" { } ''
    mkdir -p $out/komodo $out/stacks
    cp ${../../komodo/compose.yaml} $out/komodo/compose.yaml
    cp ${../fixtures/komodo.sops.env} $out/komodo/.sops.env
    # A working-tree copy can capture a developer's locally-decrypted plaintext
    # .env (gitignored on purpose) in the world-readable store.
    rm -f $out/komodo/.env
    # The remote's stack, exactly as stack-git-sync would deliver it. No
    # .sops.env by design: forgejo self-generates its keys in the volume.
    mkdir -p $out/stacks/forgejo
    cp -r ${../../stacks/forgejo}/. $out/stacks/forgejo/
    chmod -R u+w $out/stacks/forgejo
    rm -f $out/stacks/forgejo/.env
  '';

  # The project as it lives in git, under stacks/ so stack-git-sync (which
  # rsyncs the repo's stacks/ into /srv/stacks) delivers it. Two revisions, so
  # the second changes the container's definition and a redeploy is observable.
  projectV1 = pkgs.runCommand "gitops-project-v1" { } ''
    mkdir -p $out/stacks/teststack
    cat > $out/stacks/teststack/compose.yaml <<'EOF'
    services:
      gitops-test:
        image: alpine:3.21
        container_name: gitops_test
        command: ["sleep", "infinity"]
        # Consumes the host-decrypted secret, same as every production stack.
        # required:false — the decrypted .env is written host-side by
        # decrypt-sops-envs; a plain env_file would hard-fail before it exists.
        env_file:
          - path: .env
            required: false
        labels:
          revision: "one"
        restart: unless-stopped
    EOF
    # A sibling secret file: delivered by stack-git-sync, decrypted by the host
    # timer into the .env the compose above reads through env_file.
    cp ${../fixtures/ntfy.sops.env} $out/stacks/teststack/.sops.env
  '';

  projectV2 = pkgs.runCommand "gitops-project-v2" { } ''
    mkdir -p $out/stacks/teststack
    cat > $out/stacks/teststack/compose.yaml <<'EOF'
    services:
      gitops-test:
        image: alpine:3.21
        container_name: gitops_test
        command: ["sleep", "infinity"]
        # Same env_file as revision one — the redeploy must keep reading the
        # decrypted secret, not drop it with the definition change.
        env_file:
          - path: .env
            required: false
        labels:
          revision: "two"
        restart: unless-stopped
    EOF
    cp ${../fixtures/ntfy.sops.env} $out/stacks/teststack/.sops.env
  '';
in
pkgs.testers.runNixOSTest {
  name = "gitops";

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
            # Komodo (Core+Periphery+FerretDB+Postgres) rides alongside a real
            # Forgejo here; the headroom keeps the DB init and first Core connect
            # from flaking under the parallel load of `run.sh all`.
            memoryMB = 6144;
            diskMB = 12288;
          })
          (profiles.loadImages {
            inherit pkgs;
            images = stackImages;
            beforeUnits = [ "bootstrap-komodo.service" ];
          })
          {
            # stack-git-sync's TRIGGER is masked: at boot Forgejo is not up yet
            # and STACK_GIT_TOKEN still holds the fixture placeholder, so a timer
            # tick would fail its clone and ntfy-alert. The test seeds Forgejo +
            # a real token, overwrites the secret, then starts the unit by hand —
            # the unit that runs is the production one, only its trigger moves.
            systemd.timers.stack-git-sync.wantedBy = lib.mkForce [ ];
          }
        ];

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
          "d /srv/komodo 0755 root root -"
          "d /srv/stacks 0755 1000 1000 -"
          "d /var/lib/sops-nix 0700 root root -"
          "d /mnt/fast/komodo 0755 root root -"
          "d /mnt/fast/komodo/pgdata 0755 root root -"
          # The remote's volume root, owned 1000 to match its USER_UID.
          "d /mnt/fast/forgejo 0755 1000 1000 -"
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
            mkdir -p /srv/komodo /srv/stacks
            cp -r --no-preserve=mode ${seedSrv}/komodo/. /srv/komodo/
            cp -r --no-preserve=mode ${seedSrv}/stacks/. /srv/stacks/
            chown -R 1000:1000 /srv/stacks
          '';
        };

        environment.systemPackages = with pkgs; [
          git
          jq
        ];
      };
  };

  testScript = ''
    import json

    KAPI = "http://127.0.0.1:10000"
    # Komodo admin, from the komodo fixture (KOMODO_INIT_ADMIN_*).
    KADMIN = "admin"
    KPASS = "test_admin_password_not_secret"

    # The remote forge (stacks/forgejo), seeded headless below. stack-git-sync
    # hardcodes user "idan" + repo "idan/BasicBastardSelfhosted" + host
    # 127.0.0.1:10550, so the seed must match those names exactly.
    FORGE = "http://127.0.0.1:10550"
    FORGE_API = f"{FORGE}/api/v1"
    GUSER = "idan"
    GPASS = "test_forgejo_password_not_secret"
    GREPO = "BasicBastardSelfhosted"

    def diag(label):
        print(f"=== diagnostics: {label} ===")
        for cmd in [
            "docker ps -a",
            "docker logs komodo 2>&1 | tail -60",
            "docker logs komodo 2>&1 | grep -iE 'err|fail|fatal' | tail -30",
            "docker logs komodo_periphery 2>&1 | tail -40",
            "docker logs forgejo 2>&1 | tail -20",
            "ls -laR /srv/stacks | head -50",
            "journalctl -u stack-git-sync --no-pager | tail -40",
            "cat /srv/stacks/teststack/.env 2>&1 | head",
        ]:
            print("--- " + cmd)
            print(services_vm.execute(cmd)[1])

    def klogin():
        # POST /auth/login/LoginLocalUser -> {"type":"Jwt","data":{"jwt":...}}
        jwt = services_vm.succeed(
            f"curl -sf --max-time 15 -X POST {KAPI}/auth/login/LoginLocalUser "
            "-H 'Content-Type: application/json' "
            f"-d '{json.dumps({'username': KADMIN, 'password': KPASS})}' "
            "| jq -re '.data.jwt'"
        ).strip()
        assert jwt and jwt != "null", f"no jwt from komodo login: {jwt!r}"
        return jwt

    def kapi(jwt, path, body):
        # Authed POST: header `authorization: <raw jwt>`, body = params object.
        return services_vm.succeed(
            f"curl -sf --max-time 30 -X POST {KAPI}{path} "
            f"-H 'authorization: {jwt}' -H 'Content-Type: application/json' "
            f"-d '{json.dumps(body)}'"
        )

    start_all()
    services_vm.wait_for_unit("bootstrap-komodo.service")

    # -----------------------------------------------------------------------
    # Komodo boots offline and Periphery attaches over the Noise keypair
    # -----------------------------------------------------------------------
    with subtest("komodo Core answers and Periphery is connected (offline)"):
        services_vm.wait_until_succeeds(
            f"curl -s --max-time 5 {KAPI}/ -o /dev/null -w '%{{http_code}}' "
            "| grep -qE '^(2|3|4)'", timeout=300
        )
        JWT = klogin()
        # The v2 first-server model: Core auto-created "Local"; Periphery dialled
        # in and must reach state Ok before any deploy can land on it.
        try:
            services_vm.wait_until_succeeds(
                f"curl -sf -X POST {KAPI}/read/ListServers "
                f"-H 'authorization: {JWT}' -H 'Content-Type: application/json' "
                "-d '{}' | jq -re '.[] | select(.name==\"Local\") | .info.state' "
                "| grep -qx Ok",
                timeout=120,
            )
        except Exception:
            diag("periphery connect")
            raise
        global SID
        SID = services_vm.succeed(
            f"curl -sf -X POST {KAPI}/read/ListServers "
            f"-H 'authorization: {JWT}' -H 'Content-Type: application/json' "
            "-d '{}' | jq -re '.[] | select(.name==\"Local\") | .id'"
        ).strip()
        assert SID and SID != "null", f"no Local server id: {SID!r}"

    with subtest("invariant #1: the age key never entered Periphery"):
        env = services_vm.succeed(
            "docker inspect komodo_periphery --format '{{json .Config.Env}}'")
        assert "AGE-SECRET-KEY" not in env, "age secret key leaked into Periphery env"
        assert "SOPS_AGE_KEY" not in env, f"SOPS_AGE_KEY in Periphery env: {env!r}"
        mounts = services_vm.succeed(
            "docker inspect komodo_periphery --format '{{json .Mounts}}'")
        assert "sops-nix" not in mounts, f"sops key dir mounted into Periphery: {mounts!r}"

    # -----------------------------------------------------------------------
    # The remote: a real Forgejo, seeded with revision one under user "idan"
    # -----------------------------------------------------------------------
    with subtest("forgejo boots and is seeded headless (idan, token, private repo)"):
        try:
            services_vm.succeed(
                "docker compose -f /srv/stacks/forgejo/compose.yaml "
                "-p forgejo up -d --wait --wait-timeout 300"
            )
        except Exception:
            diag("forgejo up")
            raise
        # -u 1000:1000: the CLI must run as the server's uid or it creates
        # root-owned state the server cannot touch.
        services_vm.succeed(
            "docker exec -u 1000:1000 forgejo forgejo admin user create "
            f"--admin --username {GUSER} --password {GPASS} "
            "--email idan@svc.idanreed.com --must-change-password=false"
        )
        global TOKEN, PUSH_URL
        TOKEN = services_vm.succeed(
            "docker exec -u 1000:1000 forgejo forgejo admin user "
            f"generate-access-token --username {GUSER} --token-name gitops "
            "--scopes all --raw"
        ).strip()
        assert TOKEN and "\n" not in TOKEN and " " not in TOKEN, (
            f"unexpected token output: {TOKEN!r}"
        )
        # PRIVATE on purpose: stack-git-sync must authenticate to clone it,
        # which is the credentialed path this suite exists to prove.
        services_vm.succeed(
            f"curl -sf --max-time 10 -X POST -H 'Authorization: token {TOKEN}' "
            "-H 'Content-Type: application/json' "
            f"-d '{json.dumps({'name': GREPO, 'private': True, 'auto_init': False})}' "
            f"{FORGE_API}/user/repos -o /dev/null"
        )
        PUSH_URL = f"http://{GUSER}:{TOKEN}@127.0.0.1:10550/{GUSER}/{GREPO}.git"

    with subtest("revision one is pushed over authenticated http"):
        services_vm.succeed(
            "cd /root && rm -rf work && mkdir work && cd work && "
            "git init -b main . && "
            "git config user.email test@test && git config user.name test && "
            "cp -r --no-preserve=mode ${projectV1}/. . && "
            "git add -A && git commit -m 'revision one' -q && "
            f"git push -q {PUSH_URL} main"
        )
        # The credential is load-bearing: anonymous smart-http on the private
        # repo refuses...
        services_vm.fail(
            "GIT_TERMINAL_PROMPT=0 git ls-remote "
            f"http://127.0.0.1:10550/{GUSER}/{GREPO}.git"
        )
        # ...and with it the ref is served.
        services_vm.succeed(f"git ls-remote {PUSH_URL} main | grep -q main")

    # -----------------------------------------------------------------------
    # stack-git-sync (host) delivers the files; decrypt writes .env
    # -----------------------------------------------------------------------
    with subtest("stack-git-sync pulls the repo into /srv/stacks (1000:1000)"):
        # Overwrite the fixture-placeholder STACK_GIT_TOKEN with idan's real
        # token (root can write the 0400 sops secret), then run the production
        # unit by hand — its trigger is masked, its behaviour is not.
        services_vm.succeed(
            f"printf '%s' '{TOKEN}' > /run/secrets/STACK_GIT_TOKEN")
        try:
            services_vm.succeed("systemctl start stack-git-sync.service")
        except Exception:
            diag("stack-git-sync")
            raise
        services_vm.succeed("test -s /srv/stacks/teststack/compose.yaml")
        services_vm.succeed("test -s /srv/stacks/teststack/.sops.env")
        # Delivered files are chowned 1000:1000 (the /srv/stacks world).
        owner = services_vm.succeed(
            "stat -c '%u:%g' /srv/stacks/teststack/compose.yaml").strip()
        assert owner == "1000:1000", f"compose delivered as {owner}, expected 1000:1000"

    with subtest("decrypt-sops-envs turns the delivered secret into a 0600 .env"):
        # The runtime decrypt chain: file lands via stack-git-sync, .env appears
        # via the minutely timer. 150s holds a full interval plus a decrypt pass.
        services_vm.wait_until_succeeds(
            "test -s /srv/stacks/teststack/.env", timeout=150
        )
        mode = services_vm.succeed(
            "stat -c '%a' /srv/stacks/teststack/.env").strip()
        assert mode == "600", f".env is mode {mode}, expected 600"
        owner = services_vm.succeed(
            "stat -c '%u:%g' /srv/stacks/teststack/.env").strip()
        assert owner == "1000:1000", f".env owned by {owner}, expected 1000:1000"

    # -----------------------------------------------------------------------
    # Register + deploy the files_on_host Stack; the loop closes on the secret
    # -----------------------------------------------------------------------
    with subtest("Komodo deploys the files_on_host Stack and it reads the host .env"):
        create_body = {
            "name": "teststack",
            "config": {
                "server_id": SID,
                "files_on_host": True,
                "run_directory": "/srv/stacks/teststack",
                "file_paths": ["compose.yaml"],
                # 🚨 environment EMPTY so Komodo writes NO env file and cannot
                # clobber decrypt-sops-envs' .env; env_file_path points away
                # from .env as belt-and-suspenders. skip_secret_interp: Periphery
                # gets no Komodo secrets — the host already wrote them.
                "environment": "",
                "env_file_path": "komodo.env",
                "skip_secret_interp": True,
                # auto_pull=false: DeployStack defaults to `docker compose pull`
                # first, which hits the registry and FAILS in this air-gapped VM
                # (registry-1.docker.io: no such host). The test image is
                # pre-loaded from the Nix store (loadImages), exactly as the
                # offline harness requires — so skip the pull and deploy the
                # local image. Production (with egress) keeps the default true
                # and pulls the PINNED tag.
                "auto_pull": False,
            },
        }
        try:
            kapi(JWT, "/write/CreateStack", create_body)
            kapi(JWT, "/execute/DeployStack",
                 {"stack": "teststack", "services": [], "stop_time": None})
            services_vm.wait_until_succeeds(
                "docker inspect -f '{{.State.Running}}' gitops_test "
                "| grep -qx true",
                timeout=180,
            )
        except Exception:
            diag("first deploy")
            raise
        rev = services_vm.succeed(
            "docker inspect -f '{{index .Config.Labels \"revision\"}}' gitops_test"
        ).strip()
        assert rev == "one", f"deployed revision {rev!r}, expected 'one'"
        # The loop, closed on a real value: this string exists only inside the
        # encrypted fixture, so the container seeing it proves the deploy
        # actually read the HOST-decrypted .env — a .env Komodo never wrote
        # (environment=""). A container that merely runs proves none of that.
        val = services_vm.succeed(
            "docker exec gitops_test printenv NTFY_SMTP_SENDER_USER"
        ).strip()
        assert val == "test", f"NTFY_SMTP_SENDER_USER={val!r}, expected 'test'"

    with subtest("Komodo did not clobber the host .env (environment empty)"):
        # environment="" => Komodo writes no env file at all. Neither a stray
        # komodo.env nor a rewritten .env may appear.
        services_vm.fail("test -e /srv/stacks/teststack/komodo.env")
        val = services_vm.succeed(
            "grep '^NTFY_SMTP_SENDER_USER=' /srv/stacks/teststack/.env").strip()
        assert val == "NTFY_SMTP_SENDER_USER=test", f".env was altered: {val!r}"

    # -----------------------------------------------------------------------
    # Revision two: the loop closes
    # -----------------------------------------------------------------------
    with subtest("a new commit re-syncs and redeploys the changed project"):
        services_vm.succeed(
            "cd /root/work && "
            "cp -r --no-preserve=mode ${projectV2}/. . && "
            "git add -A && git commit -m 'revision two' -q && "
            f"git push -q {PUSH_URL} main"
        )
        try:
            # Re-run the host sync (production: the minutely timer) to deliver
            # the new compose...
            services_vm.succeed("systemctl start stack-git-sync.service")
            services_vm.wait_until_succeeds(
                "grep -q 'revision: \"two\"' /srv/stacks/teststack/compose.yaml",
                timeout=60,
            )
            # ...the decrypted .env must still be present for env_file...
            services_vm.succeed("test -s /srv/stacks/teststack/.env")
            # ...and a redeploy applies it (production: the /listener webhook).
            kapi(JWT, "/execute/DeployStack",
                 {"stack": "teststack", "services": [], "stop_time": None})
            services_vm.wait_until_succeeds(
                "docker inspect -f '{{index .Config.Labels \"revision\"}}' "
                "gitops_test | grep -qx two",
                timeout=300,
            )
        except Exception:
            diag("redeploy")
            raise
        # The secret survived the redeploy — not dropped with the definition.
        val = services_vm.succeed(
            "docker exec gitops_test printenv NTFY_SMTP_SENDER_USER"
        ).strip()
        assert val == "test", f"after redeploy NTFY_SMTP_SENDER_USER={val!r}"

    # -----------------------------------------------------------------------
    # The failure path: alert on state CHANGE, silent-success thereafter
    # -----------------------------------------------------------------------
    # The util suite proves this pattern for unhealthy-containers; nothing
    # proved it for stack-git-sync — whose design cost is sharper: while a
    # persistent failure is suppressed the unit reports SUCCESS, invisible to
    # `systemctl --failed` and to every failed-units sweep. This subtest is
    # the only witness that the one page it does send actually happens.
    with subtest("🚨 a broken token FAILS the sync once, then suppresses"):
        services_vm.succeed("cp /run/secrets/STACK_GIT_TOKEN /root/token.bak")
        services_vm.succeed("printf 'broken' > /run/secrets/STACK_GIT_TOKEN")
        # First run must FAIL — the exit 1 is what reaches ntfy via OnFailure.
        services_vm.fail("systemctl start stack-git-sync.service")
        services_vm.succeed("test -e /run/stack-git-sync.failed")
        # Same failure again: exit 0 by design (the state-change stamp), so a
        # down Forgejo pages once, not every minute forever.
        services_vm.succeed("systemctl start stack-git-sync.service")
        services_vm.succeed("test -e /run/stack-git-sync.failed")

    with subtest("recovery clears the stamp and says so"):
        services_vm.succeed("cp /root/token.bak /run/secrets/STACK_GIT_TOKEN")
        services_vm.succeed("systemctl start stack-git-sync.service")
        services_vm.fail("test -e /run/stack-git-sync.failed")
        journal = services_vm.succeed(
            "journalctl -u stack-git-sync.service --no-pager | tail -20"
        )
        assert "recovered" in journal, journal
  '';
}
