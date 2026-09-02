# Forgejo, proven as a GIT SERVER rather than merely a healthy container:
# headless admin bootstrap through the CLI, an API token issued by the CLI, a
# repo created through the API with that token, a real push over git-http
# WITH credentials from the host, a clone back that verifies the content
# round-tripped, and the anonymous + off-host negatives.
#
# Boots ONLY the forgejo stack on the real services-VM config —
# bootstrap-arcane is taken out of the boot path, the same trade
# lib/mk-stack-suite.nix makes (the arcane boot chain is checks.services'
# job, and the Arcane-driven GitOps loop against this same Forgejo is
# checks.gitops' job).
#
# Deliberately NOT covered here:
#   - the Caddy route (services/tailnet suites own routing)
#   - ssh access: deferred in v1 — the stack disables it, and this suite
#     asserts THAT (no second published port) rather than working around it
#   - mirroring out to GitHub (needs the internet by definition; the suites
#     are offline)

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
    images."codeberg_org_forgejo_forgejo_16_0"
  ];

  seedSrv = pkgs.runCommand "srv-seed-forgejo" { } ''
    mkdir -p $out/stacks/forgejo
    cp -r ${../../stacks/forgejo}/. $out/stacks/forgejo/
    chmod -R u+w $out/stacks/forgejo
    # A working-tree copy can capture a developer's locally-decrypted
    # plaintext .env (gitignored on purpose) in the world-readable store.
    # forgejo has no secrets by design, but keep the guard anyway.
    rm -f $out/stacks/forgejo/.env
  '';
in
pkgs.testers.runNixOSTest {
  name = "forgejo";

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
            diskMB = 10240;
          })
          (profiles.loadImages {
            inherit pkgs;
            images = stackImages;
            # Nothing container-shaped runs at boot here (bootstrap-arcane is
            # masked below), so the only contract is "loaded before the test
            # script's compose up", i.e. before the boot finishes.
            beforeUnits = [ "multi-user.target" ];
          })
        ];

        # Keep Arcane out of the boot path: its multi-hundred-MB image and
        # bootstrap ordering are irrelevant to proving the forgejo stack.
        #
        # Coverage lost: the decrypt-sops-envs -> docker-network-homelab ->
        # bootstrap-arcane chain and Arcane itself — checks.services covers
        # the chain, checks.gitops covers Arcane driving THIS forgejo.
        systemd.services.bootstrap-komodo.wantedBy = lib.mkForce [ ];
        # The new stack-git-sync timer would fail its clone every tick with no Forgejo here.
        systemd.timers.stack-git-sync.wantedBy = lib.mkForce [ ];

        # decrypt-sops-envs.service `requires = srv.mount`; without a real
        # mount unit it never starts. tmpfs gives a genuine .mount unit, and
        # /mnt/fast backs the stack's /data volume root.
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
          # The stack's volume root, owned 1000 to match USER_UID — the same
          # ownership world as /srv/stacks (finding #10). The image's
          # entrypoint would chown what it creates anyway; pre-creating it
          # keeps the suite honest about the path the compose file names.
          "d /mnt/fast/forgejo 0755 1000 1000 -"
        ];

        # Populate /srv before anything reads it; on the real host Arcane's
        # git sync plays this role.
        systemd.services.seed-srv = {
          description = "Seed /srv with the forgejo stack (test only)";
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
          git
          jq
        ];
      };

    # Another host on the LAN, for the off-host negative. As everywhere in
    # this harness: the probe proves FIREWALL posture (nothing but 22 open to
    # the VLAN), not the loopback bind itself — the interface that could
    # expose a 0.0.0.0 publish is the trusted tailscale0, which needs a real
    # tailnet peer (tailnet.nix's job).
    outsider = { };
  };

  testScript = ''
    import json

    PORT = 10550
    BASE = f"http://127.0.0.1:{PORT}"
    API = f"{BASE}/api/v1"
    COMPOSE = "docker compose -f /srv/stacks/forgejo/compose.yaml -p forgejo"

    ADMIN = "forgeadmin"
    # Test-only credential, VM-local, never leaves this suite. The real
    # instance gets its admin created the same headless way at deploy time,
    # with a real password.
    PASSWORD = "test_forgejo_password_not_secret"
    PAYLOAD = "forgejo-proof-payload-9c2f"

    def diag(label):
        print(f"=== diagnostics: {label} ===")
        for cmd in [
            f"{COMPOSE} ps -a",
            f"{COMPOSE} logs --tail=100",
            # Binary/CLI discovery aid: where the forgejo/gitea entrypoints
            # actually live in this image revision.
            "docker exec forgejo ls -la /usr/local/bin /app/gitea 2>&1 | head -20",
            "ls -la /mnt/fast/forgejo/data 2>&1 | head -10",
            "journalctl -u docker --no-pager -o cat | tail -20",
        ]:
            print("--- " + cmd)
            print(services_vm.execute(cmd)[1])

    start_all()
    services_vm.wait_for_unit("multi-user.target")

    # -----------------------------------------------------------------------
    # Boot the stack
    # -----------------------------------------------------------------------
    with subtest("the forgejo stack comes up healthy (its healthcheck IS /api/healthz)"):
        try:
            # --wait gates on the compose healthcheck, which curls
            # /api/healthz inside the container — so a green here already
            # proves the health endpoint, DB init and key generation.
            services_vm.succeed(f"{COMPOSE} up -d --wait --wait-timeout 300")
        except Exception:
            diag("compose up")
            raise

    with subtest("healthz answers on loopback from the host"):
        services_vm.succeed(f"curl -sf --max-time 10 {BASE}/api/healthz")

    # -----------------------------------------------------------------------
    # Headless bootstrap: admin + token via the CLI
    # -----------------------------------------------------------------------
    with subtest("the admin user is created headless via the CLI"):
        # CLI discovery: the image ships the binary as `forgejo` on PATH
        # (with a gitea-compat alias). Print the version so a future image
        # bump that renames it fails with the answer already in the log.
        print(services_vm.succeed("docker exec forgejo forgejo --version"))
        # -u 1000:1000, not root: the CLI must run as the same uid as the
        # server (USER_UID) or it creates root-owned state the server then
        # cannot touch; the image's env (GITEA_CUSTOM=/data/gitea) points
        # the exec'd CLI at the generated app.ini.
        try:
            services_vm.succeed(
                "docker exec -u 1000:1000 forgejo forgejo admin user create "
                f"--admin --username {ADMIN} --password {PASSWORD} "
                "--email forgeadmin@svc.idanreed.com --must-change-password=false"
            )
        except Exception:
            diag("admin user create")
            raise

    with subtest("the CLI issues an API token"):
        global TOKEN
        try:
            TOKEN = services_vm.succeed(
                "docker exec -u 1000:1000 forgejo forgejo admin user "
                f"generate-access-token --username {ADMIN} "
                "--token-name harness --scopes all --raw"
            ).strip()
        except Exception:
            diag("generate-access-token")
            raise
        assert TOKEN and " " not in TOKEN and "\n" not in TOKEN, (
            f"unexpected token output: {TOKEN!r}"
        )

    # -----------------------------------------------------------------------
    # A repo, over the API; content, over git-http
    # -----------------------------------------------------------------------
    with subtest("a private repo is created through the API with the token"):
        try:
            out = services_vm.succeed(
                f"curl -sf --max-time 10 -X POST "
                f"-H 'Authorization: token {TOKEN}' "
                "-H 'Content-Type: application/json' "
                "-d '{\"name\":\"proof\",\"private\":true,\"auto_init\":false}' "
                f"{API}/user/repos"
            )
        except Exception:
            print(services_vm.execute(
                f"curl -si --max-time 10 -X POST -H 'Authorization: token {TOKEN}' "
                "-H 'Content-Type: application/json' "
                "-d '{\"name\":\"proof\",\"private\":true,\"auto_init\":false}' "
                f"{API}/user/repos | head -25")[1])
            diag("repo create")
            raise
        repo = json.loads(out)
        assert repo.get("name") == "proof", f"unexpected repo response: {out[:200]}"

    with subtest("git push over http WITH credentials lands the content"):
        # Token as the basic-auth password — the v1 access mode, and exactly
        # what Arcane/CI will do against forgejo.svc.idanreed.com.
        push_url = f"http://{ADMIN}:{TOKEN}@127.0.0.1:{PORT}/{ADMIN}/proof.git"
        services_vm.succeed(
            "cd /root && rm -rf work && mkdir work && cd work && "
            "git init -b main . && "
            "git config user.email test@test && git config user.name test && "
            f"echo '{PAYLOAD}' > README.md && "
            "git add -A && git commit -q -m seed && "
            f"git push -q {push_url} main"
        )

    with subtest("a fresh clone returns the same content"):
        services_vm.succeed(
            f"cd /root && rm -rf out && git clone -q {push_url} out && "
            f"grep -qx '{PAYLOAD}' out/README.md"
        )
        # Commit-hash round trip, not just file content: the object store
        # itself must have survived, not merely a checkout of it.
        pushed = services_vm.succeed("git -C /root/work rev-parse HEAD").strip()
        cloned = services_vm.succeed("git -C /root/out rev-parse HEAD").strip()
        assert pushed == cloned, f"HEAD drifted: pushed {pushed}, cloned {cloned}"

    # -----------------------------------------------------------------------
    # Negatives
    # -----------------------------------------------------------------------
    with subtest("anonymous access to the private repo is refused"):
        # GIT_TERMINAL_PROMPT=0: without it git hangs asking for a username
        # instead of failing.
        services_vm.fail(
            "GIT_TERMINAL_PROMPT=0 git ls-remote "
            f"http://127.0.0.1:{PORT}/{ADMIN}/proof.git"
        )
        # And the API view of it: no token, no repo (Forgejo answers 404,
        # not 401, to avoid confirming private repo names — accept either).
        code = services_vm.succeed(
            # Plain string on purpose: %{http_code} is curl syntax, and an
            # f-string would eat the braces.
            "curl -s --max-time 10 -o /dev/null -w '%{http_code}' "
            + f"{API}/repos/{ADMIN}/proof"
        ).strip()
        assert code in ("401", "404"), f"anonymous API read returned {code}"

    with subtest("only the web port is published, on loopback, and the LAN cannot reach it"):
        ports = services_vm.succeed("docker port forgejo").strip().splitlines()
        assert ports, "docker port printed nothing"
        for line in ports:
            # ssh is deferred in v1: any published port besides 3000->10550
            # (e.g. a 22) means the compose drifted from the design note.
            assert line.startswith("3000/tcp -> 127.0.0.1:"), (
                f"unexpected published port: {line!r}"
            )
        outsider.fail(f"nc -z -w 5 services-vm {PORT}")
        outsider.fail("nc -z -w 5 services-vm 3000")

    with subtest("no unit is left failed at suite end"):
        failed = services_vm.succeed("systemctl --failed --no-legend").strip()
        assert failed == "", f"failed units at suite end:\n{failed}"
  '';
}
