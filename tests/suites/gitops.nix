# The Arcane GitOps loop, for real: push -> sync -> deploy -> update.
#
# Every other suite drives `docker compose` by hand and treats Arcane as a
# service to health-check. This one exercises what Arcane is actually FOR:
#   (a) a git repository is registered through the API and a GitOps sync
#       created for a project inside it
#   (b) triggering a sync clones the repo, copies the WHOLE project directory
#       (compose.yaml AND the sibling .sops.env — the v1.17 directory-sync
#       behaviour CLAUDE.md documents as the reason the fork retired)
#   (c) the delivered .sops.env is decrypted by the host timer within a tick —
#       the runtime-sync chain the decrypt-sops-envs fix exists for — and the
#       resulting .env is chowned so Arcane (PUID 1000) can deploy with it
#   (d) Arcane deploys the project AFTER the decrypt; the container actually
#       runs and, via env_file, SEES the fixture secret — delivery -> decrypt
#       -> deploy, the whole loop closed on a value that exists only encrypted
#   (e) a second push + sync REDEPLOYS the change (the container reflects the
#       new definition)
#
# The remote is the REAL Forgejo stack (stacks/forgejo) in the same VM,
# seeded through its own headless path: CLI admin + CLI-issued token, repo
# via the API, the project pushed over git-http WITH credentials. Arcane
# dials it with authType http + username/token — the exact production shape
# once the repo lives at forgejo.svc.idanreed.com. This retires the
# git-daemon/git:// transport substitution this suite used to carry (its
# header said the substitution would go when Forgejo landed — it has; the
# forgejo suite covers the stack on its own, this one covers Arcane
# consuming it with credentials).
#
# One test-only wire remains: Arcane's container is connected to the
# forgejo_default network at runtime (`docker network connect`), because the
# production route — https://forgejo.svc.idanreed.com through Caddy bound to
# a tailnet IP — has no tailnet to ride inside this VM, and the host port is
# (correctly) loopback-only, unreachable from a container. The smart-HTTP
# protocol and the credential exchange are identical either way; only the L3
# path differs. Coverage lost: the Caddy hop and TLS, owned by the
# services/tailnet suites' routing assertions.
#
# The API shapes were probed against the deployed 1.17.4 via its OpenAPI
# document (the repo create-DTO rejects unknown properties; the 1.16-era bulk
# sync trigger is gone — autoSync on an interval is the mechanism). The repo
# create-DTO's auth fields: authType (none|http|ssh) + username + token.

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
    images."ghcr_io_getarcaneapp_arcane_v1_17_4"
    # The remote: the real forgejo stack, playing the production forge.
    images."codeberg_org_forgejo_forgejo_16_0"
    # The test project's container image; pinned and preloaded like all others.
    images."alpine_3_21"
  ];

  seedSrv = pkgs.runCommand "srv-seed-gitops" { } ''
    mkdir -p $out/arcane $out/stacks
    cp ${../../arcane/compose.yaml} $out/arcane/compose.yaml
    cp ${../fixtures/arcane.sops.env} $out/arcane/.sops.env
    # A working-tree copy can capture a developer's locally-decrypted
    # plaintext .env (gitignored on purpose) in the world-readable store.
    rm -f $out/arcane/.env
    # The remote's stack, exactly as Arcane would have delivered it on the
    # real host. No .sops.env by design: forgejo self-generates its keys in
    # the volume (see the stack's header).
    mkdir -p $out/stacks/forgejo
    cp -r ${../../stacks/forgejo}/. $out/stacks/forgejo/
    chmod -R u+w $out/stacks/forgejo
    rm -f $out/stacks/forgejo/.env
  '';

  # The project as it lives in git. Two revisions, staged as directories the
  # test script commits in order — the second changes the container's
  # definition so a redeploy is observable.
  projectV1 = pkgs.runCommand "gitops-project-v1" { } ''
    mkdir -p $out/teststack
    cat > $out/teststack/compose.yaml <<'EOF'
    services:
      gitops-test:
        image: alpine:3.21
        container_name: gitops_test
        command: ["sleep", "infinity"]
        # Consumes the host-decrypted secret, same as every production stack;
        # the test script therefore deploys only AFTER the decrypt gate, so
        # the up cannot race the timer into unset variables.
        # required:false — finding #11: Arcane validates in a staging dir
        # where the host-decrypted .env cannot exist; plain env_file aborts
        # the whole sync there.
        env_file:
          - path: .env
            required: false
        labels:
          revision: "one"
        restart: unless-stopped
    EOF
    # A sibling secret file: delivered by directory sync, decrypted by the
    # host timer into the .env the compose above reads through env_file.
    cp ${../fixtures/ntfy.sops.env} $out/teststack/.sops.env
  '';

  projectV2 = pkgs.runCommand "gitops-project-v2" { } ''
    mkdir -p $out/teststack
    cat > $out/teststack/compose.yaml <<'EOF'
    services:
      gitops-test:
        image: alpine:3.21
        container_name: gitops_test
        command: ["sleep", "infinity"]
        # Same env_file as revision one — the redeploy must keep reading the
        # decrypted secret, not drop it with the definition change.
        # required:false — finding #11: Arcane validates in a staging dir
        # where the host-decrypted .env cannot exist; plain env_file aborts
        # the whole sync there.
        env_file:
          - path: .env
            required: false
        labels:
          revision: "two"
        restart: unless-stopped
    EOF
    cp ${../fixtures/ntfy.sops.env} $out/teststack/.sops.env
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
            # 3072 sufficed with git-daemon as the remote; forgejo (sqlite,
            # but a real forge) rides alongside arcane now, and the extra GB
            # keeps a slow first-start from flaking the --wait window.
            memoryMB = 4096;
            diskMB = 12288;
          })
          (profiles.loadImages {
            inherit pkgs;
            images = stackImages;
            beforeUnits = [ "bootstrap-arcane.service" ];
          })
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
          "d /srv/arcane 0755 root root -"
          "d /srv/stacks 0755 1000 1000 -"
          "d /var/lib/sops-nix 0700 root root -"
          # The remote's volume root, owned 1000 to match its USER_UID (the
          # same ownership world as /srv/stacks — finding #10).
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
            mkdir -p /srv/arcane /srv/stacks
            cp -r --no-preserve=mode ${seedSrv}/arcane/. /srv/arcane/
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

    API = "http://127.0.0.1:10000/api"
    JAR = "/tmp/arcane-cookies"
    # Session-cookie auth; every call goes through the jar.
    CURL = f"curl -sf --max-time 20 -b {JAR} -c {JAR} -H 'Content-Type: application/json'"

    # The remote forge (stacks/forgejo), seeded headless below.
    FORGE_API = "http://127.0.0.1:10550/api/v1"
    ADMIN = "forgeadmin"
    # Test-only credential, VM-local — the real instance gets its admin
    # created the same headless way at deploy time, with a real password.
    PASSWORD = "test_forgejo_password_not_secret"

    def diag(label):
        print(f"=== diagnostics: {label} ===")
        for cmd in [
            "docker logs arcane 2>&1 | tail -50",
            "docker logs forgejo 2>&1 | tail -30",
            "docker ps -a",
            "ls -laR /srv/stacks | head -40",
            f"curl -si --max-time 10 -b {JAR} {API}/environments | head -20",
        ]:
            print("--- " + cmd)
            print(services_vm.execute(cmd)[1])

    start_all()
    services_vm.wait_for_unit("bootstrap-arcane.service")
    services_vm.wait_until_succeeds(
        "curl -sf --max-time 5 http://127.0.0.1:10000/ -o /dev/null", timeout=180
    )

    # -----------------------------------------------------------------------
    # The remote: a real Forgejo, seeded with revision one
    # -----------------------------------------------------------------------
    with subtest("forgejo boots and is seeded headless (admin, token, private repo)"):
        # The stack's own healthcheck is /api/healthz; --wait gates on it.
        try:
            services_vm.succeed(
                "docker compose -f /srv/stacks/forgejo/compose.yaml "
                "-p forgejo up -d --wait --wait-timeout 300"
            )
        except Exception:
            diag("forgejo up")
            raise
        # -u 1000:1000: the CLI must run as the server's uid (USER_UID) or
        # it creates root-owned state the server cannot touch.
        services_vm.succeed(
            "docker exec -u 1000:1000 forgejo forgejo admin user create "
            f"--admin --username {ADMIN} --password {PASSWORD} "
            "--email forgeadmin@svc.idanreed.com --must-change-password=false"
        )
        global TOKEN, PUSH_URL
        TOKEN = services_vm.succeed(
            "docker exec -u 1000:1000 forgejo forgejo admin user "
            f"generate-access-token --username {ADMIN} --token-name gitops "
            "--scopes all --raw"
        ).strip()
        assert TOKEN and "\n" not in TOKEN and " " not in TOKEN, (
            f"unexpected token output: {TOKEN!r}"
        )
        # PRIVATE on purpose: Arcane must authenticate to clone it, which is
        # the credentialed path this suite upgrade exists to prove.
        services_vm.succeed(
            f"curl -sf --max-time 10 -X POST -H 'Authorization: token {TOKEN}' "
            "-H 'Content-Type: application/json' "
            "-d '{\"name\":\"remote\",\"private\":true,\"auto_init\":false}' "
            f"{FORGE_API}/user/repos -o /dev/null"
        )
        PUSH_URL = f"http://{ADMIN}:{TOKEN}@127.0.0.1:10550/{ADMIN}/remote.git"

    with subtest("revision one is pushed over authenticated http"):
        services_vm.succeed(
            "cd /root && rm -rf work && mkdir work && cd work && "
            "git init -b main . && "
            "git config user.email test@test && git config user.name test && "
            "cp -r --no-preserve=mode ${projectV1}/. . && "
            "git add -A && git commit -m 'revision one' -q && "
            f"git push -q {PUSH_URL} main"
        )
        # The credential is load-bearing: anonymous smart-http on the
        # private repo refuses (GIT_TERMINAL_PROMPT=0 or git hangs asking)...
        services_vm.fail(
            "GIT_TERMINAL_PROMPT=0 git ls-remote "
            f"http://127.0.0.1:10550/{ADMIN}/remote.git"
        )
        # ...and with it the ref is served.
        services_vm.succeed(f"git ls-remote {PUSH_URL} main | grep -q main")

    with subtest("arcane gets a route to the forge (test-only network connect)"):
        # The host port is loopback-only (correct — Caddy is the only path
        # in) and a container cannot reach a loopback-bound host port, so
        # Arcane joins forgejo's compose network to stand in for the
        # production tailnet+Caddy route. See the header for exactly what
        # this does and does not substitute.
        services_vm.succeed("docker network connect forgejo_default arcane")
        global GIT_URL
        GIT_URL = f"http://forgejo:3000/{ADMIN}/remote.git"

    # -----------------------------------------------------------------------
    # Drive the API
    # -----------------------------------------------------------------------
    with subtest("login and register the repository + sync"):
        try:
            services_vm.succeed(
                f"{CURL} -X POST -d "
                "'{\"username\":\"arcane\",\"password\":\"arcane-admin\"}' "
                f"{API}/auth/login -o /dev/null"
            )
        except Exception:
            print(services_vm.execute(
                f"curl -si --max-time 10 -X POST -H 'Content-Type: application/json' "
                "-d '{\"username\":\"arcane\",\"password\":\"arcane-admin\"}' "
                f"{API}/auth/login | head -25")[1])
            diag("login")
            raise

        env_id = services_vm.succeed(
            f"{CURL} {API}/environments | jq -r '.data[0].id'"
        ).strip()
        assert env_id and env_id != "null", f"no environment id: {env_id!r}"

        # No 'branch' here: 1.17.4's create-DTO rejects unknown properties
        # (422 unexpected property body.branch) — the branch belongs to the
        # sync, not the repository. Auth per the DTO (authType none|http|ssh
        # + username/token): http with the CLI-issued token, the production
        # shape against a real forge.
        repo_body = json.dumps({
            "name": "test-remote",
            "url": GIT_URL,
            "authType": "http",
            "username": ADMIN,
            "token": TOKEN,
        })
        try:
            repo_id = services_vm.succeed(
                f"{CURL} -X POST -d '{repo_body}' "
                f"{API}/customize/git-repositories | jq -r '.data.id'"
            ).strip()
            assert repo_id and repo_id != "null", f"no repository id: {repo_id!r}"
        except Exception:
            # 1.17.4's real surface, from the horse's mouth: Huma serves the
            # OpenAPI document. Dump every git-ish path + the raw response.
            print(services_vm.execute(
                f"curl -s -b {JAR} {API}/openapi.json "
                "| jq -r '.paths | keys[]' | grep -iE 'git|repo' | head -20")[1])
            print(services_vm.execute(
                f"curl -si -b {JAR} -H 'Content-Type: application/json' "
                f"-X POST -d '{repo_body}' "
                f"{API}/customize/git-repositories | head -25")[1])
            diag("repo create")
            raise

        # Print the deployed version's create-DTO before using it — the field
        # set (sync mode, deploy behaviour) is exactly what drifted since the
        # 1.16 source this suite was first written against.
        schema_jq = (
            ".paths[\"/environments/{id}/gitops-syncs\"].post.requestBody"
            ".content[\"application/json\"].schema as $s | "
            "if $s[\"$ref\"] then .components.schemas[($s[\"$ref\"] | split(\"/\") | last)] "
            "else $s end"
        )
        # The jq program contains double quotes but no single quotes, so a
        # plain single-quote wrap is shell-safe.
        print(services_vm.succeed(
            f"curl -s -b {JAR} {API}/openapi.json | jq '{schema_jq}'"
        ))

        sync_body = json.dumps({
            "name": "teststack",
            "repositoryId": repo_id,
            "branch": "main",
            "composePath": "teststack/compose.yaml",
            "projectName": "teststack",
            "autoSync": True,
            "syncInterval": 1,
            # Off by default in 1.17.4 despite the upstream changelog phrasing
            # ("single file sync mode" in the logs); without it the sibling
            # .sops.env never leaves the repo.
            "syncDirectory": True,
        })
        try:
            services_vm.succeed(
                f"{CURL} -X POST -d '{sync_body}' "
                f"{API}/environments/{env_id}/gitops-syncs -o /dev/null"
            )
        except Exception:
            # Dump the deployed version's actual create schema.
            print(services_vm.execute(
                f"curl -s -b {JAR} {API}/openapi.json | jq -r "
                "'.paths[\"/environments/{id}/gitops-syncs\"].post.requestBody"
                ".content[\"application/json\"].schema'")[1])
            print(services_vm.execute(
                f"curl -si -b {JAR} -H 'Content-Type: application/json' "
                f"-X POST -d '{sync_body}' "
                f"{API}/environments/{env_id}/gitops-syncs | tail -5")[1])
            raise

    with subtest("autoSync delivers the project within its interval"):
        # 1.17.4's sync DELIVERS files and registers a project; it has no
        # deploy flag at all (the create-DTO above is the proof). Deployment
        # is a separate, explicit action — and it happens only AFTER the
        # decrypt gate below, because the compose consumes .env via env_file.
        # autoSync on the 1-minute interval is the production cadence.
        try:
            services_vm.wait_until_succeeds(
                "test -s /srv/stacks/teststack/compose.yaml", timeout=180
            )
        except Exception:
            diag("first sync")
            raise

    with subtest("directory sync delivered the sibling secret, and the host decrypted it"):
        # The v1.17 behaviour the fork existed for, plus the runtime decrypt
        # chain: file lands via Arcane, .env appears via the minutely timer.
        # Gating the deploy on this is the production ordering — delivery ->
        # decrypt -> deploy — not a test convenience.
        services_vm.succeed("test -s /srv/stacks/teststack/.sops.env")
        # 150s: worst case the delivery lands just after a timer tick, so the
        # budget must hold a full minutely interval plus a decrypt pass — 90s
        # left almost no slack over that.
        services_vm.wait_until_succeeds(
            "test -s /srv/stacks/teststack/.env", timeout=150
        )
        # The decrypt script chowns to 1000:1000 so Arcane (PUID 1000) can
        # read it at deploy time — existence alone would pass with a
        # root-owned .env that compose-in-Arcane cannot open.
        owner = services_vm.succeed(
            "stat -c '%u:%g' /srv/stacks/teststack/.env"
        ).strip()
        assert owner == "1000:1000", f".env owned by {owner}, expected 1000:1000"

    with subtest("deploying the synced project runs the container"):
        # The project id materialises on the sync record once the first sync
        # completes.
        project_id = services_vm.wait_until_succeeds(
            f"{CURL} {API}/environments/{env_id}/gitops-syncs "
            "| jq -re '.data[0].projectId // empty'",
            timeout=60,
        ).strip()
        try:
            services_vm.succeed(
                f"{CURL} -X POST "
                f"{API}/environments/{env_id}/projects/{project_id}/up "
                "-o /dev/null"
            )
            services_vm.wait_until_succeeds(
                "docker inspect -f '{{.State.Running}}' gitops_test "
                "| grep -qx true",
                timeout=120,
            )
        except Exception:
            print(services_vm.execute(
                f"curl -s -b {JAR} {API}/openapi.json "
                "| jq -r '.paths | keys[] | select(test(\"projects\"))' | head -20")[1])
            print(services_vm.execute(
                f"curl -si -b {JAR} -X POST "
                f"{API}/environments/{env_id}/projects/{project_id}/up | head -15")[1])
            diag("first deploy")
            raise
        rev = services_vm.succeed(
            "docker inspect -f '{{index .Config.Labels \"revision\"}}' gitops_test"
        ).strip()
        assert rev == "one", f"deployed revision {rev!r}, expected 'one'"
        # The loop, closed on a real value: this string exists only inside the
        # encrypted fixture, so the container seeing it proves the
        # Arcane-driven deploy actually read the host-decrypted .env — a
        # container that merely runs proves none of that.
        val = services_vm.succeed(
            "docker exec gitops_test printenv NTFY_SMTP_SENDER_USER"
        ).strip()
        assert val == "test", f"NTFY_SMTP_SENDER_USER={val!r}, expected 'test'"

    # -----------------------------------------------------------------------
    # Revision two: the loop closes
    # -----------------------------------------------------------------------
    with subtest("a new commit redeploys the changed project"):
        services_vm.succeed(
            "cd /root/work && "
            "cp -r --no-preserve=mode ${projectV2}/. . && "
            "git add -A && git commit -m 'revision two' -q && "
            f"git push -q {PUSH_URL} main"
        )
        try:
            # Sync tick delivers the new file...
            services_vm.wait_until_succeeds(
                "grep -q 'revision: \"two\"' /srv/stacks/teststack/compose.yaml",
                timeout=180,
            )
            # ...the decrypted .env must still be there for env_file (a sync
            # rewriting the directory plus a decrypt-timer race could leave a
            # window without it; wait like the first deploy did)...
            services_vm.wait_until_succeeds(
                "test -s /srv/stacks/teststack/.env", timeout=150
            )
            # ...and an explicit up applies it.
            services_vm.succeed(
                f"{CURL} -X POST "
                f"{API}/environments/{env_id}/projects/{project_id}/up "
                "-o /dev/null"
            )
            # 300 not 120: under a parallel `run.sh all` this VM shares the host
            # with several others, and the recreate exceeded 120s once (sweep
            # 12e) while passing alone — the wait is load-bound, not broken.
            services_vm.wait_until_succeeds(
                "docker inspect -f '{{index .Config.Labels \"revision\"}}' "
                "gitops_test | grep -qx two",
                timeout=300,
            )
        except Exception:
            diag("redeploy")
            raise
  '';
}
