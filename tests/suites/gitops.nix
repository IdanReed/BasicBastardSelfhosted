# The deploy path, for real, OFFLINE: push -> Forgejo webhook -> Komodo `apply`
# procedure -> sync -> deploy-if-changed, against a live Komodo (Core +
# Periphery + FerretDB + Postgres) and a live Forgejo, both run from the flake
# by their production host units and loaded from the Nix store. Nothing on the
# host signals Komodo: the only trigger is Forgejo's own push webhook.
#
# The chain, and who owns each link:
#   (a) forgejo.service and bootstrap-komodo.service bring both up from the
#       store; Periphery dials Core over the Noise keypair (no passkey).
#   (b) the operator's bring-up, simulated: a `komodo` bot gets a read token
#       (production: sopsedit komodo/secrets.sops.json + switch; here the
#       published Core config is rewritten and komodo-core-reload runs).
#   (c) the repo is pushed, and the production komodo-sync-bootstrap creates
#       the `fleet` sync and the `apply` procedure from the REAL
#       komodo/fleet.toml, then runs the sync — which registers the test stack
#       (tagged `gitops`) and leaves everything untagged alone.
#   (d) Forgejo's push webhook (signed with KOMODO_WEBHOOK_SECRET, sent as
#       X-Hub-Signature-256) reaches `apply`; Periphery clones from
#       forgejo:3000 over the homelab network and deploys. The container sees a
#       value that exists only encrypted in the fixture: the env sops-nix
#       rendered on the host, passed by path, never written by Komodo.
#   (e) a compose change redeploys; a CIPHERTEXT change after a "switch"
#       re-rendered the env redeploys with the new value — the secrets path.
#
# The stack is named after a fixture with an env (ntfy), so its
# /run/stack-env/ntfy.env is rendered by the real stack-env module; its compose
# is a sleeping alpine, not the real ntfy.
#
# The API contract, verified against komodo 2.3.4:
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
    images."ghcr_io_moghtech_komodo-core_2_3_4"
    images."ghcr_io_moghtech_komodo-periphery_2_3_4"
    images."ghcr_io_ferretdb_ferretdb_2_7_0"
    images."ghcr_io_ferretdb_postgres-documentdb_17-0_107_0-ferretdb-2_7_0"
    images."codeberg_org_forgejo_forgejo_16_0"
    # The test stack's container image; pinned and preloaded like all others.
    images."alpine_3_21"
  ];

  # The test repo's stacks.toml: one block, the production shape
  # (komodo-sync-coverage) plus auto_pull = false — DeployStack would otherwise
  # `docker compose pull` first, which fails in this air-gapped VM; the image is
  # preloaded from the store instead.
  testStacksToml = pkgs.writeText "stacks.toml" ''
    [[stack]]
    name = "ntfy"
    tags = ["gitops"]
    [stack.config]
    server = "Local"
    git_provider = "forgejo:3000"
    git_https = false
    git_account = "komodo"
    repo = "idan/BasicBastardSelfhosted"
    branch = "main"
    run_directory = "stacks/ntfy"
    file_paths = ["compose.yaml"]
    additional_env_files = [{ path = "/run/stack-env/ntfy.env", track = false }]
    config_files = [
      { path = "secrets.sops.json", requires = "Redeploy" },
      { path = "greeting.txt", services = ["gitops-test"], requires = "Restart" },
    ]
    auto_pull = false
  '';

  compose =
    revision:
    pkgs.writeText "compose-${revision}.yaml" ''
      services:
        gitops-test:
          image: alpine:3.21
          container_name: gitops_test
          command: ["sleep", "infinity"]
          # The host-rendered env, by path — the same line every stack has.
          env_file: /run/stack-env/ntfy.env
          # A single-file bind of a repo file, the shape a Caddyfile has.
          volumes:
            - ./greeting.txt:/greeting:ro
          labels:
            revision: "${revision}"
          restart: unless-stopped
    '';

  # The repo as pushed: the test stacks.toml and the stack (compose + the
  # ciphertext its env is rendered from). komodo/fleet.toml is not needed in
  # it: the host applies that file from the store.
  repoV1 = pkgs.runCommand "gitops-repo-v1" { } ''
    mkdir -p $out/komodo/sync $out/stacks/ntfy
    cp ${testStacksToml} $out/komodo/sync/stacks.toml
    cp ${compose "one"} $out/stacks/ntfy/compose.yaml
    echo hello > $out/stacks/ntfy/greeting.txt
    cp ${../fixtures/stacks/ntfy.sops.json} $out/stacks/ntfy/secrets.sops.json
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
            beforeUnits = [
              "bootstrap-komodo.service"
              "forgejo.service"
            ];
          })
        ];

        # The sync bootstrap's TRIGGER moves: at boot Forgejo holds no repo and
        # no bot token yet, so it would fail. The script runs the production
        # unit by hand once (b) and (c) are in place.
        systemd.services.komodo-sync-bootstrap.wantedBy = lib.mkForce [ ];

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
          "d /var/lib/sops-nix 0700 root root -"
          "d /mnt/fast/komodo 0755 root root -"
          "d /mnt/fast/komodo/pgdata 0755 root root -"
          # The forge's volume root, owned 1000 to match its USER_UID.
          "d /mnt/fast/forgejo 0755 1000 1000 -"
        ];

        environment.systemPackages = with pkgs; [
          git
          jq
        ];
      };
  };

  testScript = ''
    import json

    KAPI = "http://127.0.0.1:10000"
    FORGE = "http://127.0.0.1:10550"
    FORGE_API = f"{FORGE}/api/v1"
    GUSER = "idan"
    GPASS = "test_forgejo_password_not_secret"
    GREPO = "BasicBastardSelfhosted"
    BOT = "komodo"
    BOTPASS = "test_komodo_bot_password_not_secret"

    def diag(label):
        print(f"=== diagnostics: {label} ===")
        for cmd in [
            "docker ps -a",
            "docker logs komodo 2>&1 | tail -60",
            "docker logs komodo_periphery 2>&1 | tail -40",
            "docker logs forgejo 2>&1 | tail -30",
            "journalctl -u komodo-sync-bootstrap --no-pager | tail -30",
            "ls -la /srv/komodo/stacks /srv/komodo/stacks/ntfy 2>&1 | head -30",
        ]:
            print("--- " + cmd)
            print(services_vm.execute(cmd)[1])

    def env_value(key):
        # The rendered env single-quotes every value.
        line = services_vm.succeed(
            f"grep '^{key}=' /run/stack-env/komodo.env").strip()
        return line.split("=", 1)[1].strip("'")

    def klogin():
        body = json.dumps({"username": env_value("KOMODO_INIT_ADMIN_USERNAME"),
                           "password": env_value("KOMODO_INIT_ADMIN_PASSWORD")})
        cmd = (f"curl -sf --max-time 15 -X POST {KAPI}/auth/login/LoginLocalUser "
               f"-H 'Content-Type: application/json' -d '{body}' | jq -re '.data.jwt'")
        # Core restarts on a git-config change; wait it out rather than race it.
        services_vm.wait_until_succeeds(cmd, timeout=180)
        jwt = services_vm.succeed(cmd).strip()
        assert jwt and jwt != "null", f"no jwt from komodo login: {jwt!r}"
        return jwt

    def kapi(path, body):
        return services_vm.succeed(
            f"curl -sf --max-time 30 -X POST {KAPI}{path} "
            f"-H 'authorization: {klogin()}' -H 'Content-Type: application/json' "
            f"-d '{json.dumps(body)}'"
        )

    def periphery_ok():
        services_vm.wait_until_succeeds(
            f"curl -sf -X POST {KAPI}/read/ListServers "
            f"-H 'authorization: {klogin()}' -H 'Content-Type: application/json' "
            "-d '{}' | jq -re '.[] | select(.name==\"Local\") | .info.state' "
            "| grep -qx Ok",
            timeout=180,
        )

    def deployed(revision, timeout=300):
        services_vm.wait_until_succeeds(
            "docker inspect -f '{{index .Config.Labels \"revision\"}}' gitops_test "
            f"| grep -qx {revision}",
            timeout=timeout,
        )

    def push(message):
        services_vm.succeed(
            "cd /root/work && git add -A && "
            f"git commit -q -m '{message}' && git push -q {PUSH_URL} main"
        )

    start_all()
    services_vm.wait_for_unit("bootstrap-komodo.service")
    services_vm.wait_for_unit("forgejo.service")

    # -----------------------------------------------------------------------
    # (a) both planes up from the store, offline
    # -----------------------------------------------------------------------
    with subtest("Komodo Core answers and Periphery is connected (offline)"):
        services_vm.wait_until_succeeds(
            f"curl -s --max-time 5 {KAPI}/ -o /dev/null -w '%{{http_code}}' "
            "| grep -qE '^(2|3|4)'", timeout=300
        )
        try:
            periphery_ok()
        except Exception:
            diag("periphery connect")
            raise

    with subtest("invariant #1: the age key never entered Periphery"):
        env = services_vm.succeed(
            "docker inspect komodo_periphery --format '{{json .Config.Env}}'")
        assert "AGE-SECRET-KEY" not in env, "age secret key leaked into Periphery env"
        assert "SOPS_AGE_KEY" not in env, f"SOPS_AGE_KEY in Periphery env: {env!r}"
        mounts = services_vm.succeed(
            "docker inspect komodo_periphery --format '{{json .Mounts}}'")
        assert "sops-nix" not in mounts, f"sops key dir mounted into Periphery: {mounts!r}"
        assert "/run/secrets" not in mounts.replace("/run/stack-env", ""), \
            f"Periphery mounts /run/secrets (a generation symlink): {mounts!r}"

    with subtest("Forgejo is healthy, seeded headless, and on the homelab network"):
        try:
            services_vm.wait_until_succeeds(
                f"curl -sf --max-time 5 {FORGE}/api/healthz", timeout=300)
        except Exception:
            diag("forgejo up")
            raise
        nets = services_vm.succeed(
            "docker inspect forgejo --format '{{json .NetworkSettings.Networks}}'")
        assert "homelab" in nets, f"forgejo is not on homelab: {nets}"
        # -u 1000:1000: the CLI must run as the server's uid.
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
        assert TOKEN and " " not in TOKEN, f"unexpected token output: {TOKEN!r}"
        services_vm.succeed(
            f"curl -sf --max-time 10 -X POST -H 'Authorization: token {TOKEN}' "
            "-H 'Content-Type: application/json' "
            f"-d '{json.dumps({'name': GREPO, 'private': True, 'auto_init': False})}' "
            f"{FORGE_API}/user/repos -o /dev/null"
        )
        PUSH_URL = f"http://{GUSER}:{TOKEN}@127.0.0.1:10550/{GUSER}/{GREPO}.git"

    # -----------------------------------------------------------------------
    # (b) the bot's read token reaches Core
    # -----------------------------------------------------------------------
    with subtest("the komodo bot reads the private repo with a read-only token"):
        services_vm.succeed(
            "docker exec -u 1000:1000 forgejo forgejo admin user create "
            f"--username {BOT} --password {BOTPASS} "
            "--email komodo@svc.idanreed.com --must-change-password=false"
        )
        services_vm.succeed(
            f"curl -sf --max-time 10 -X PUT -H 'Authorization: token {TOKEN}' "
            "-H 'Content-Type: application/json' -d '{\"permission\":\"read\"}' "
            f"{FORGE_API}/repos/{GUSER}/{GREPO}/collaborators/{BOT}"
        )
        bot_token = services_vm.succeed(
            "docker exec -u 1000:1000 forgejo forgejo admin user "
            f"generate-access-token --username {BOT} --token-name komodo "
            "--scopes read:repository --raw"
        ).strip()
        # Production: sopsedit komodo/secrets.sops.json (KOMODO_GIT_TOKEN) and
        # switch — sops-nix re-renders the Core config, stack-env-publish copies
        # it, komodo-core-reload restarts Core. Here the published file is
        # written directly and the same reload unit runs.
        cfg = ('[[git_provider]]\\ndomain = "forgejo:3000"\\nhttps = false\\n'
               f'accounts = [{{ username = "komodo", token = "komodo:{bot_token}" }}]\\n')
        services_vm.succeed(
            f"printf '%b' '{cfg}' > /run/stack-env/komodo-core.config.toml")
        services_vm.succeed("systemctl start komodo-core-reload.service")
        periphery_ok()

    # -----------------------------------------------------------------------
    # (c) the repo is pushed and the fleet sync registers everything
    # -----------------------------------------------------------------------
    with subtest("komodo-sync-bootstrap creates fleet + apply and registers the stack"):
        services_vm.succeed(
            "mkdir -p /root/work && cd /root/work && git init -q -b main . && "
            "git config user.email test@test && git config user.name test && "
            "cp -r --no-preserve=mode ${repoV1}/. . && "
            "git add -A && git commit -q -m 'revision one' && "
            f"git push -q {PUSH_URL} main"
        )
        try:
            services_vm.succeed("systemctl start komodo-sync-bootstrap.service")
        except Exception:
            diag("sync bootstrap")
            raise
        kapi("/read/GetProcedure", {"procedure": "apply"})
        stack = json.loads(kapi("/read/GetStack", {"stack": "ntfy"}))
        assert stack["config"]["repo"] == f"{GUSER}/{GREPO}", stack["config"]
        # delete = true never reached past the `gitops` tag: what Core made for
        # itself on first start is untouched...
        kapi("/read/GetServer", {"server": "Local"})
        kapi("/read/GetBuilder", {"builder": "Local"})
        for name in ("Backup Core Database", "Global Auto Update", "Rotate Server Keys"):
            kapi("/read/GetProcedure", {"procedure": name})
        # ...and a second sync over the same commit has nothing to change —
        # above all not the sync or `apply`, which a running `apply` could
        # never update.
        upd = json.loads(kapi("/execute/RunSync", {"sync": "fleet"}))
        uid = upd["_id"]["$oid"]
        services_vm.wait_until_succeeds(
            f"curl -sf --max-time 15 -X POST {KAPI}/read/GetUpdate "
            f"-H 'authorization: {klogin()}' -H 'Content-Type: application/json' "
            f"-d '{json.dumps({'id': uid})}' | jq -e '.status == \"Complete\"'",
            timeout=120)
        logs = json.loads(kapi("/read/GetUpdate", {"id": uid}))["logs"]
        assert any("nothing to do" in log.get("stdout", "") for log in logs), logs
        # Registration is not deployment: nothing runs until apply does.
        services_vm.fail("docker inspect gitops_test")
        # And a re-run (every boot, every switch that changes fleet.toml)
        # converges instead of failing on what already exists.
        services_vm.succeed("systemctl restart komodo-sync-bootstrap.service")
        out = services_vm.succeed(
            "journalctl -u komodo-sync-bootstrap --no-pager -o cat | tail -6")
        assert "Procedure apply matches komodo/fleet.toml" in out, out
        assert "every stack in komodo/sync/ is registered" in out, out

    # -----------------------------------------------------------------------
    # (d) Forgejo's push webhook deploys
    # -----------------------------------------------------------------------
    with subtest("an unsigned or mis-signed call to the listener is refused"):
        url = f"{KAPI}/listener/github/procedure/apply/main"
        body = '{"ref":"refs/heads/main"}'
        code = services_vm.succeed(
            f"curl -s -o /dev/null -w '%{{http_code}}' -X POST {url} "
            f"-H 'Content-Type: application/json' -d '{body}'").strip()
        assert code == "401", f"unsigned webhook got {code}"
        code = services_vm.succeed(
            f"curl -s -o /dev/null -w '%{{http_code}}' -X POST {url} "
            "-H 'X-Hub-Signature-256: sha256=00' "
            f"-H 'Content-Type: application/json' -d '{body}'").strip()
        assert code == "401", f"mis-signed webhook got {code}"

    with subtest("Forgejo's signed push webhook runs apply and deploys revision one"):
        secret = env_value("KOMODO_WEBHOOK_SECRET")
        hook = {
            "type": "forgejo",
            "active": True,
            "events": ["push"],
            "branch_filter": "main",
            "config": {
                "url": "http://komodo:9120/listener/github/procedure/apply/main",
                "content_type": "json",
                "secret": secret,
            },
        }
        hook_id = services_vm.succeed(
            f"curl -sf --max-time 10 -X POST -H 'Authorization: token {TOKEN}' "
            f"-H 'Content-Type: application/json' -d '{json.dumps(hook)}' "
            f"{FORGE_API}/repos/{GUSER}/{GREPO}/hooks | jq -r .id"
        ).strip()
        # Forgejo's "Test Delivery": a signed push payload for the head commit,
        # the same delivery a push makes.
        services_vm.succeed(
            f"curl -sf --max-time 10 -X POST -H 'Authorization: token {TOKEN}' "
            f"{FORGE_API}/repos/{GUSER}/{GREPO}/hooks/{hook_id}/tests")
        try:
            deployed("one")
        except Exception:
            diag("webhook deploy")
            raise
        # The loop closed on a value that exists only encrypted in the
        # fixture: the host-rendered env, read by path.
        val = services_vm.succeed(
            "docker exec gitops_test printenv NTFY_SMTP_SENDER_USER").strip()
        assert val == "test", f"NTFY_SMTP_SENDER_USER={val!r}, expected 'test'"

    with subtest("Periphery deployed from its own clone and wrote no env file"):
        run_dir = "/srv/komodo/stacks/ntfy/stacks/ntfy"
        services_vm.succeed(f"test -s {run_dir}/compose.yaml")
        services_vm.fail(f"test -e {run_dir}/.env")
        services_vm.fail(f"test -e {run_dir}/komodo.env")

    # -----------------------------------------------------------------------
    # (e) changes land on push
    # -----------------------------------------------------------------------
    with subtest("a compose change redeploys on push"):
        services_vm.succeed(
            "cp --no-preserve=mode ${compose "two"} /root/work/stacks/ntfy/compose.yaml")
        push("revision two")
        try:
            deployed("two")
        except Exception:
            diag("compose redeploy")
            raise

    with subtest("a change to ONLY a bind-mounted file restarts its consumer"):
        # Untracked, it would never count as a change; tracked as Restart,
        # Komodo pulls and restarts the service, which re-binds by path (git
        # replaced the file, so the old mount still shows the old inode).
        started = services_vm.succeed(
            "docker inspect -f '{{.State.StartedAt}}' gitops_test").strip()
        services_vm.succeed("echo goodbye > /root/work/stacks/ntfy/greeting.txt")
        push("change only the greeting")
        try:
            services_vm.wait_until_succeeds(
                "docker exec gitops_test cat /greeting | grep -qx goodbye", timeout=300)
        except Exception:
            diag("config-file restart")
            raise
        now = services_vm.succeed(
            "docker inspect -f '{{.State.StartedAt}}' gitops_test").strip()
        assert now != started, "the consumer was not restarted"

    with subtest("a secrets change redeploys with the re-rendered value"):
        started = services_vm.succeed(
            "docker inspect -f '{{.State.StartedAt}}' gitops_test").strip()
        # Production order: switch first (sops-nix re-renders, publish copies),
        # then push the new ciphertext. Simulated: the published env changes,
        # then a commit changes ONLY secrets.sops.json.
        services_vm.succeed(
            "sed -i \"s/^NTFY_SMTP_SENDER_USER=.*/NTFY_SMTP_SENDER_USER='rotated'/\" "
            "/run/stack-env/ntfy.env")
        services_vm.succeed(
            "cd /root/work && jq '.rotated = \"marker\"' stacks/ntfy/secrets.sops.json "
            "> s.json && mv s.json stacks/ntfy/secrets.sops.json")
        push("rotate a secret")
        services_vm.wait_until_succeeds(
            "docker exec gitops_test printenv NTFY_SMTP_SENDER_USER "
            "| grep -qx rotated", timeout=300)
        now = services_vm.succeed(
            "docker inspect -f '{{.State.StartedAt}}' gitops_test").strip()
        assert now != started, "the container was not recreated"

    with subtest("no unit is left failed"):
        failed = services_vm.succeed(
            "systemctl --failed --no-legend --plain | awk '{print $1}'").split()
        assert not failed, f"failed units: {failed}"
  '';
}
