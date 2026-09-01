# Actual Budget suite: the sync server and the HTTP one-shot that closes the
# bake-off's open question.
#
# Hand-written, NOT in stackChecks: actual_init is a restart:"no" one-shot
# that must exit, which fails mk-stack-suite's all-containers-running check
# (the beszel/tandoor precedent) — and the thing most worth testing here is
# the init's semantics, which the generic suite cannot see.
#
# Genuinely under test:
#   - 🚨 **The headless bootstrap path the bake-off marked UNVERIFIED.**
#     service-bakeoff.md flagged "first-run sets a password in-browser" and
#     left POST /account/bootstrap as an unverified rumor. The source
#     (app-account.js at v26.9.0) says it is real; this suite is what proves
#     it against the shipped image: actual_init POSTs the fixture password,
#     and a subsequent /account/login with that password must return a token.
#     "Bootstrap returned ok" alone would also be true of a server that
#     stored a mangled password — the login is the assertion that counts.
#   - 🚨 **The server is never up-and-claimable.** Before init runs the
#     server IS serving with no password set, and /account/bootstrap is
#     unauthenticated — whoever posts first owns the server. The mitigations
#     are the loopback-only publish (asserted from the outsider) and init
#     running in the same compose up; the residue is documented below.
#   - **State lands on the bind mount as uid 1001.** The compose file's
#     `user: "1001:1001"` pin (the published image creates uid 1001 but
#     ships NO USER instruction — this suite's first run measured
#     account.sqlite owned 0:0 without the pin) plus the create-folders
#     migration mean a root-owned /mnt/fast/actual fails the first
#     migration and the container exits before serving. The tmpfiles rule
#     here is 1001:1001 like production's (generate-stack-dirs.py
#     DIR_NOTES) — and account.sqlite existing under server-files/ owned
#     1001 afterwards is what proves the whole chain, including that the
#     pin took effect.
#   - **init fails closed**: empty password AND a changeme_ placeholder both
#     exit 1 before any HTTP — the placeholder case is the sharp one, since
#     the server would happily bootstrap with a password that sits in a
#     public git repo.
#   - **init is idempotent**: a rerun (every Arcane redeploy) logs zero
#     CHANGE lines. Deliberately NOT re-verifying the password on rerun —
#     an in-app password change is legitimate and must not fail deploys.
#   - **OIDC is really off**: the fixture carries ACTUAL_OPENID_CLIENT_*
#     values, and loginMethod must still come back "password" — the env vars
#     alone must be inert (no discovery URL, no enable-openid run).
#
# Documented gaps:
#   - **The /health liveness lie is not demonstrated**, only documented: it
#     is a bare express 200 with no storage check, so a full or read-only
#     /data leaves the healthcheck green. Making /mnt/fast/actual read-only
#     mid-suite to prove it would leave SQLite in a state the reboot subtest
#     could not distinguish from a real regression.
#   - **OIDC enable path.** scripts/enable-openid.js needs a reachable
#     issuer; the offline VM has none. Ships ready-and-off; the off state is
#     what is asserted.
#   - **SimpleFIN.** Native, but the credential is pasted in the client UI
#     and the bridge is on the internet — nothing automated can cover it.
#   - **Rate limiting is respected, not tested**: /account/bootstrap and
#     /account/login share ONE 5-per-15-min limiter keyed by client IP.
#     Init spends 2 from its bridge IP; this script spends at most 3 from
#     the host gateway IP before the reboot (which resets the in-memory
#     limiter). Adding login assertions here has a budget.

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
    # One image, on purpose — actual_init runs on the server image.
    images."actualbudget_actual-server_26_9_0"
  ];

  seedSrv = pkgs.runCommand "srv-seed-actual" { } ''
    mkdir -p $out/stacks/actual
    cp -r ${../../stacks/actual}/. $out/stacks/actual/
    chmod -R u+w $out/stacks/actual
    # A developer's locally-decrypted plaintext .env is gitignored but would
    # still be captured by cp -r into the world-readable store.
    rm -f $out/stacks/actual/.env
    rm -f $out/stacks/actual/.sops.env.example $out/stacks/actual/.sops.env
    cp ${../fixtures/actual.sops.env} $out/stacks/actual/.sops.env
  '';
in
pkgs.testers.runNixOSTest {
  name = "actual";

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
            memoryMB = 2560;
            diskMB = 8192;
          })
          (profiles.loadImages {
            inherit pkgs;
            images = stackImages;
            beforeUnits = [ "multi-user.target" ];
          })
        ];

        systemd.services.bootstrap-arcane.wantedBy = lib.mkForce [ ];
        virtualisation.cores = lib.mkForce 2;

        virtualisation.emptyDiskImages = [ 2048 ];
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
          # 🚨 1001:1001, matching production's DIR_NOTES entry: the compose
          # file pins `user: "1001:1001"` (the published image creates uid
          # 1001 but ships NO USER instruction — measured, see the compose
          # header) and the create-folders migration mkdirs under /data
          # before the server ever binds. Root-owned, the container exits at
          # start — which is the failure this rule's production twin exists
          # to prevent.
          "d /mnt/fast/actual 0755 1001 1001 -"
        ];

        systemd.services.seed-srv = {
          description = "Seed /srv with the actual stack (test only)";
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

    outsider = { };
  };

  testScript = ''
    import json

    AB = "docker compose -f /srv/stacks/actual/compose.yaml -p actual"
    BASE = "http://127.0.0.1:10308"
    PASSWORD = "test_actual_password_not_secret"
    IMG = "actualbudget/actual-server:26.9.0"

    def diag(label):
        print("=== diagnostics: " + label + " ===")
        for cmd in [
            "docker ps -a",
            "docker logs actual 2>&1 | tail -50",
            "docker logs actual_init 2>&1 | tail -40",
            "ls -laR /mnt/fast/actual 2>&1 | head -40",
            "df -h /var/lib/docker /mnt; free -m",
        ]:
            print("--- " + cmd)
            print(services_vm.execute(cmd)[1])

    def login(password):
        # ⚠ Shares the 5-per-15-min limiter with /bootstrap (one instance,
        # keyed by client IP). Count call sites before adding more.
        body = json.dumps({"loginMethod": "password", "password": password})
        raw = services_vm.succeed(
            "curl -s --max-time 30 -X POST -H 'Content-Type: application/json' "
            f"-d '{body}' {BASE}/account/login"
        )
        return json.loads(raw)

    start_all()

    with subtest("the fixture .sops.env decrypted to a 0600 .env"):
        services_vm.wait_for_unit("multi-user.target")
        services_vm.wait_for_unit("docker-network-homelab.service")
        services_vm.wait_until_succeeds("test -s /srv/stacks/actual/.env", timeout=120)
        stat = services_vm.succeed("stat -c '%a %u:%g' /srv/stacks/actual/.env").strip()
        assert stat == "600 1000:1000", f".env is {stat}"
        for k in ["ACTUAL_INIT_PASSWORD", "ACTUAL_OPENID_CLIENT_ID",
                  "ACTUAL_OPENID_CLIENT_SECRET"]:
            services_vm.succeed(f"grep -q '^{k}=.' /srv/stacks/actual/.env")

    services_vm.wait_for_unit("load-test-images.service")

    with subtest("compose up: server healthy, init ran and exited 0"):
        try:
            # Start EVERYTHING first — enumerating services in the --wait
            # call below means only those get created, and the init
            # container would never run at all (the tandoor lesson).
            services_vm.succeed(f"{AB} up -d")
            services_vm.succeed(f"{AB} up -d --wait --wait-timeout 300 actual")
            services_vm.wait_until_succeeds(
                "docker inspect -f '{{.State.Status}}/{{.State.ExitCode}}' "
                "actual_init | grep -qx exited/0",
                timeout=300,
            )
        except Exception:
            diag("compose up failed")
            raise
        logs = services_vm.succeed("docker logs actual_init 2>&1")
        assert "CHANGE: bootstrapped the server password" in logs, logs
        assert "verified — login with the bootstrapped password returns a token" in logs, logs

    with subtest("🚨 the server is bootstrapped, and OIDC env vars were inert"):
        state = json.loads(services_vm.succeed(
            f"curl -fsS --max-time 30 {BASE}/account/needs-bootstrap"
        ))["data"]
        assert state["bootstrapped"] is True, state
        # The fixture .env carries ACTUAL_OPENID_CLIENT_ID/SECRET. With no
        # discovery URL and no enable-openid run they must change NOTHING —
        # if this ever comes back "openid" the ships-off posture is broken
        # and the first login through the tailnet claims ownership forever.
        assert state["loginMethod"] == "password", state

    with subtest("🚨 the fixture password really is the credential (bake-off claim, closed)"):
        res = login(PASSWORD)
        assert res.get("status") == "ok" and res["data"].get("token"), res

    with subtest("a wrong password is refused"):
        res = login("not-the-password")
        assert res.get("status") == "error", res
        assert not (res.get("data") or {}).get("token"), res

    with subtest("state landed on the bind mount, owned by uid 1001"):
        # account.sqlite existing under server-files proves the whole chain:
        # migrations ran, as uid 1001, against the bind mount — not against
        # a path inside the container's writable layer.
        services_vm.succeed("test -f /mnt/fast/actual/server-files/account.sqlite")
        services_vm.succeed("test -d /mnt/fast/actual/user-files")
        owner = services_vm.succeed(
            "stat -c %u:%g /mnt/fast/actual/server-files/account.sqlite"
        ).strip()
        assert owner == "1001:1001", f"account.sqlite is owned {owner}"

    with subtest("actual_init is idempotent — a redeploy changes nothing"):
        services_vm.succeed("docker rm -f actual_init")
        services_vm.succeed(f"{AB} up -d actual_init")
        services_vm.wait_until_succeeds(
            "docker inspect -f '{{.State.Status}}/{{.State.ExitCode}}' "
            "actual_init | grep -qx exited/0",
            timeout=120,
        )
        logs = services_vm.succeed("docker logs actual_init 2>&1")
        assert "CHANGE:" not in logs, f"second run mutated something:\n{logs}"
        assert "already bootstrapped" in logs, logs

    with subtest("🚨 init fails closed: empty password"):
        # Same image, entrypoint tini kept, no network needed — both guards
        # must trip before any HTTP happens.
        rc, out = services_vm.execute(
            "docker run --rm -e ACTUAL_INIT_PASSWORD= "
            "-v /srv/stacks/actual/actual-init.js:/init/actual-init.js:ro "
            f"{IMG} node /init/actual-init.js 2>&1"
        )
        assert rc != 0, f"init exited 0 with an empty password:\n{out}"
        assert "empty or unset" in out, out

    with subtest("🚨 init fails closed: changeme_ placeholder"):
        # The sharp case: the SERVER would accept this string happily, and a
        # finance server would then be guarded by a password that sits in a
        # public git repo.
        rc, out = services_vm.execute(
            "docker run --rm -e ACTUAL_INIT_PASSWORD=changeme_strong_password "
            "-v /srv/stacks/actual/actual-init.js:/init/actual-init.js:ro "
            f"{IMG} node /init/actual-init.js 2>&1"
        )
        assert rc != 0, f"init exited 0 with a placeholder password:\n{out}"
        assert "placeholder" in out, out

    with subtest("🚨 10308 is unreachable from another machine"):
        # Load-bearing beyond the house rule: between `up` and init's exit
        # the server is briefly serving with NO password and an open
        # unauthenticated /account/bootstrap. Loopback-only publishing is
        # what confines that window to the host itself.
        ip = services_vm.succeed(
            "ip -4 -o addr show eth1 | awk '{print $4}' | cut -d/ -f1"
        ).strip()
        outsider.wait_for_unit("network.target")
        outsider.fail(f"curl -s --max-time 10 http://{ip}:10308/health >/dev/null")
        outsider.succeed(f"ping -c1 -W5 {ip} >/dev/null")

    with subtest("state survives a reboot"):
        services_vm.shutdown()
        services_vm.start()
        services_vm.wait_for_unit("multi-user.target")
        services_vm.wait_until_succeeds("test -s /srv/stacks/actual/.env", timeout=180)
        services_vm.wait_for_unit("load-test-images.service")
        # rm the old init container FIRST: it is already exited/0 from before
        # the reboot, so without this the wait below could pass against the
        # stale state while the rerun was still in flight — and its logs
        # would carry the pre-reboot lines.
        services_vm.succeed("docker rm -f actual_init")
        services_vm.succeed(f"{AB} up -d")
        services_vm.succeed(f"{AB} up -d --wait --wait-timeout 300 actual")
        services_vm.wait_until_succeeds(
            "docker inspect -f '{{.State.Status}}/{{.State.ExitCode}}' "
            "actual_init | grep -qx exited/0",
            timeout=120,
        )
        logs = services_vm.succeed("docker logs actual_init 2>&1")
        assert "CHANGE:" not in logs, f"post-reboot rerun mutated something:\n{logs}"
        # The in-memory rate limiter died with the old process; this is the
        # first login in the new window.
        res = login(PASSWORD)
        assert res.get("status") == "ok" and res["data"].get("token"), res
  '';
}
