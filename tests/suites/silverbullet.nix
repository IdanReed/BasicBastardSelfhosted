# SilverBullet suite: the git-sync path against a REAL Forgejo remote — the
# leg stackChecks.silverbullet structurally cannot see (its fixture's remote
# points at 127.0.0.1:10550 with no Forgejo in that VM, so only the local
# half of the sidecar ever runs there).
#
# The staging trick: the fixture's GIT_SYNC_REMOTE is
#   http://test:test_pat_not_secret@127.0.0.1:10550/test/space.git
# and instead of rewriting .env (which the minutely decrypt timer would
# revert), this suite makes REALITY match the fixture: a Forgejo user `test`
# with that password and a private repo `test/space`. The sidecar is
# host-networked, so the fixture URL works verbatim — the exact credential
# path production uses, including basic-auth over the loopback publish.
#
# Genuinely under test:
#   - 🚨 the three measured traps' observables (compose.yaml header):
#     "Shell running disabled." present (the documented 2.9.0 bump gate,
#     finding #64), the shell-enabled line absent, no read-only mode
#     (finding #62 — SB_READ_ONLY is presence-tested and must stay unset);
#   - the sidecar seeds the remote branch, then a page written into the
#     space (name WITH a space — the IFS trap in git-sync.sh) is committed,
#     pushed, and clones back with its content — falsifying the
#     "debounce never quiets, mirror never advances" hypothesis;
#   - PAT hygiene: no `origin` remote is ever configured and the PAT never
#     lands in /space/.git/config (inside the backup set);
#   - REMOTE WINS, the quiet case (finding #66): a page edited on both sides
#     comes out as the remote's version with NO git error — asserted via the
#     superseded branch, the reconciled-remote-wins ntfy alert, and the
#     on-disk content;
#   - the CONTAINER_BOOT.md canary (finding #63): the file appearing in the
#     space alerts and is NOT deleted;
#   - health-through-failure: a dead Forgejo alerts ("NOT mirrored") while
#     BOTH containers stay healthy — the designed decoupling of the wiki
#     from its mirror.
#
# Documented gaps:
#   - recovery after the remote returns (the suite ends with Forgejo down;
#     the loop's next ls-remote would resume — unproven here);
#   - the UNRESOLVABLE-conflict rescue path (rescue_and_reset: delete/modify
#     etc. — only the -X-ours-resolves case is driven);
#   - port exposure from off-host — stackChecks.silverbullet keeps that leg;
#   - SB_USER's login gate (the wiki's own auth) is never exercised.
#
# Timing: production values (INTERVAL=60, DEBOUNCE=30) are used unmodified —
# overriding them would test a different container — so sync waits are sized
# in cycles (240-300s). The sidecar's ALERT_COOLDOWN=3600 means one ntfy
# alert per hour: each alert-asserting leg clears /tmp/git-sync.last-alert
# in the container first (staging, not a semantics change).

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
    images."ghcr_io_silverbulletmd_silverbullet_2_9_0"
    images."alpine_git_v2_54_0"
    images."codeberg_org_forgejo_forgejo_16_0"
    images."binwiederhier_ntfy_v2_11_0"
  ];

  seedSrv = pkgs.runCommand "srv-seed-silverbullet" { } ''
    for s in silverbullet forgejo ntfy; do
      mkdir -p $out/stacks/$s
      cp -r ${../../stacks}/$s/. $out/stacks/$s/
      chmod -R u+w $out/stacks/$s
      rm -f $out/stacks/$s/.env $out/stacks/$s/.sops.env.example $out/stacks/$s/.sops.env
    done
    cp ${../fixtures/silverbullet.sops.env} $out/stacks/silverbullet/.sops.env
    cp ${../fixtures/ntfy.sops.env} $out/stacks/ntfy/.sops.env
  '';

  # Real ownership rows for all three stacks (space and forgejo are
  # 1000:1000, ntfy root:root) from the generated file production imports.
  stackDirRules = lib.filter (
    r:
    lib.any (p: lib.hasInfix p r) [
      "/mnt/fast/silverbullet"
      "/mnt/fast/forgejo"
      "/mnt/fast/ntfy"
    ]
  ) (import ../../nixos/stack-dirs.nix).systemd.tmpfiles.rules;
in
pkgs.testers.runNixOSTest {
  name = "silverbullet";

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
        # The Forgejo here serves the WIKI mirror, not the compose repo —
        # stack-git-sync would still fail its clone (no BasicBastardSelfhosted
        # repo) every tick.
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
    SPACE = "/mnt/fast/silverbullet/space"
    # Matches the fixture's GIT_SYNC_REMOTE byte for byte — see the header.
    GUSER = "test"
    GPASS = "test_pat_not_secret"
    REMOTE = f"http://{GUSER}:{GPASS}@127.0.0.1:10550/{GUSER}/space.git"
    NTFY = "http://127.0.0.1:10001/alerts/json?poll=1&since=all"
    # The page name CONTAINS A SPACE on purpose: git-sync.sh's superseded
    # loop splits on IFS, and page names with spaces are the ones a default
    # IFS would silently mis-handle.
    PAGE = "Phase2 Test.md"

    def diag(label):
        print("=== diagnostics: " + label + " ===")
        for cmd in [
            "docker ps -a",
            "docker logs silverbullet 2>&1 | tail -40",
            "docker logs silverbullet_gitsync 2>&1 | tail -60",
            "docker logs forgejo 2>&1 | tail -20",
            f"ls -la {SPACE} 2>&1",
            f"git -C {SPACE} log --oneline -8 2>&1; git -C {SPACE} branch -a 2>&1",
        ]:
            print("--- " + cmd)
            print(services_vm.execute(cmd)[1])

    def clear_alert_cooldown():
        # ALERT_COOLDOWN=3600 is global in the sidecar; each alert leg gets
        # a fresh window. Staging only — the cooldown logic itself is not
        # under test here.
        services_vm.succeed(
            "docker exec silverbullet_gitsync rm -f /tmp/git-sync.last-alert"
        )

    def write_page(content):
        # As uid 1000, the owner the server and sidecar share.
        services_vm.succeed(
            f"printf '%s\\n' '{content}' > '{SPACE}/{PAGE}' "
            f"&& chown 1000:1000 '{SPACE}/{PAGE}'"
        )

    start_all()

    with subtest("decrypt-sops-envs produced the sidecar's .env (remote + PAT)"):
        services_vm.wait_for_unit("multi-user.target")
        services_vm.wait_for_unit("docker-network-homelab.service")
        services_vm.wait_until_succeeds(
            "test -s /srv/stacks/silverbullet/.env", timeout=120
        )
        services_vm.succeed(
            "grep -q '^GIT_SYNC_REMOTE=http://test:' /srv/stacks/silverbullet/.env"
        )
        services_vm.succeed("grep -q '^SB_USER=.' /srv/stacks/silverbullet/.env")

    services_vm.wait_for_unit("load-test-images.service")

    with subtest("ntfy and forgejo come up; reality is made to match the fixture"):
        try:
            services_vm.succeed(
                "docker compose -f /srv/stacks/ntfy/compose.yaml "
                "-p ntfy up -d --wait --wait-timeout 300"
            )
            services_vm.succeed(
                "docker compose -f /srv/stacks/forgejo/compose.yaml "
                "-p forgejo up -d --wait --wait-timeout 300"
            )
        except Exception:
            diag("ntfy/forgejo up")
            raise
        # -u 1000:1000: the CLI must run as the server's uid (gitops.nix).
        services_vm.succeed(
            "docker exec -u 1000:1000 forgejo forgejo admin user create "
            f"--username {GUSER} --password {GPASS} "
            "--email test@svc.idanreed.com --must-change-password=false"
        )
        # PRIVATE repo via basic auth — the same credential shape the
        # sidecar's URL carries.
        services_vm.succeed(
            f"curl -sf --max-time 10 -u {GUSER}:{GPASS} -X POST "
            "-H 'Content-Type: application/json' "
            "-d '{\"name\": \"space\", \"private\": true, \"auto_init\": false}' "
            "http://127.0.0.1:10550/api/v1/user/repos -o /dev/null"
        )
        # The credential is load-bearing: anonymous smart-http refuses...
        services_vm.fail(
            "GIT_TERMINAL_PROMPT=0 git ls-remote "
            f"http://127.0.0.1:10550/{GUSER}/space.git"
        )
        # ...and with it the (empty) repo answers.
        services_vm.succeed(f"GIT_TERMINAL_PROMPT=0 git ls-remote {REMOTE}")

    with subtest("the wiki stack comes up healthy"):
        try:
            services_vm.succeed(
                "docker compose -f /srv/stacks/silverbullet/compose.yaml "
                "-p silverbullet up -d --wait --wait-timeout 300"
            )
        except Exception:
            diag("silverbullet up")
            raise

    with subtest("🚨 the three traps' observables (the 2.9.0 bump gate)"):
        logs = services_vm.succeed("docker logs silverbullet 2>&1")
        # Positive control for the negatives below: the startup banner is
        # being read at all. This exact line is why the pin stays on 2.9.0
        # (finding #64) — 2.10.0 removes it along with the proof.
        assert "Shell running disabled." in logs, (
            "the shell-disabled line is missing — either SB_SHELL_BACKEND=off "
            "was dropped (trap 1 is live) or the image was bumped past the "
            "release that logs the proof (finding #64: re-measure first)"
        )
        assert "enabled for ALL commands" not in logs, (
            "shell execution is ENABLED — SB_SHELL_BACKEND=off lost"
        )
        # Trap 2: SB_READ_ONLY is presence-tested; setting it AT ALL turns
        # read-only on and every edit silently fails behind a green health.
        assert "read-only" not in logs.lower(), (
            "read-only mode mentioned at startup — SB_READ_ONLY crept in"
        )

    with subtest("the sidecar seeds the remote branch from the fresh space"):
        # First cycle: git init, .gitignore, first commit, push seeds main.
        services_vm.wait_until_succeeds(
            f"GIT_TERMINAL_PROMPT=0 git ls-remote --exit-code {REMOTE} "
            "refs/heads/main",
            timeout=240,
        )
        services_vm.succeed(f"test -f {SPACE}/.gitignore")
        services_vm.succeed(
            f"grep -q silverbullet.auth.json {SPACE}/.gitignore"
        )

    with subtest("a page written into the space is committed and mirrored"):
        write_page("phase2 marker ONE")
        # DEBOUNCE=30 quiet + a 60s cycle: comfortably inside 300s.
        services_vm.wait_until_succeeds(
            "rm -rf /root/checkout && "
            f"GIT_TERMINAL_PROMPT=0 git clone -q {REMOTE} /root/checkout && "
            f"grep -q 'phase2 marker ONE' '/root/checkout/{PAGE}'",
            timeout=300,
        )

    with subtest("PAT hygiene: no origin remote, no credential in .git/config"):
        # Positive control: the config file exists and is a real git repo's.
        services_vm.succeed(f"test -f {SPACE}/.git/config")
        services_vm.fail(f"grep -q {GPASS} {SPACE}/.git/config")
        remotes = services_vm.succeed(f"git -C {SPACE} remote").strip()
        assert remotes == "", f"a named remote is configured: {remotes!r}"

    with subtest("REMOTE WINS on a both-sides edit — branch, alert, content"):
        clear_alert_cooldown()
        # Local edit first: the 30s debounce guarantees it cannot be
        # committed before the remote edit lands, which makes the conflict
        # deterministic (the sidecar will replay the local commit onto the
        # already-pushed remote head).
        write_page("phase2 marker LOCAL")
        services_vm.succeed(
            "cd /root/checkout && "
            f"printf 'phase2 marker REMOTE\\n' > '{PAGE}' && "
            "git config user.email obsidian@test && git config user.name obsidian && "
            "git add -A && git commit -q -m 'remote edit' && "
            f"GIT_TERMINAL_PROMPT=0 git push -q {REMOTE} main"
        )
        # -X ours resolves REMOTE-wins with no git error (finding #66); the
        # only detectable traces are the three asserted here.
        services_vm.wait_until_succeeds(
            f"grep -q 'phase2 marker REMOTE' '{SPACE}/{PAGE}'", timeout=300
        )
        services_vm.succeed(
            f"git -C {SPACE} branch --list 'git-sync-superseded-*' | grep -q ."
        )
        services_vm.wait_until_succeeds(
            f"curl -s --max-time 10 '{NTFY}' | grep -q 'reconciled remote-wins'",
            timeout=120,
        )
        # The superseded branch still holds the local version — nothing lost
        # from history.
        sup = services_vm.succeed(
            f"git -C {SPACE} branch --list 'git-sync-superseded-*' | head -1"
        ).strip().lstrip("* ")
        services_vm.succeed(
            f"git -C {SPACE} show '{sup}:{PAGE}' | grep -q 'phase2 marker LOCAL'"
        )

    with subtest("the CONTAINER_BOOT.md canary alerts and does NOT delete"):
        clear_alert_cooldown()
        services_vm.succeed(
            f"touch '{SPACE}/CONTAINER_BOOT.md' "
            f"&& chown 1000:1000 '{SPACE}/CONTAINER_BOOT.md'"
        )
        services_vm.wait_until_succeeds(
            f"curl -s --max-time 10 '{NTFY}' | grep -q 'CONTAINER_BOOT.md'",
            timeout=180,
        )
        # Deliberate non-deletion (finding #63): the operator may have put
        # it there; deleting evidence is its own silent failure.
        services_vm.succeed(f"test -f '{SPACE}/CONTAINER_BOOT.md'")
        services_vm.succeed(f"rm '{SPACE}/CONTAINER_BOOT.md'")

    with subtest("a dead remote alerts NOT-mirrored while BOTH stay healthy"):
        clear_alert_cooldown()
        services_vm.succeed("docker stop forgejo")
        services_vm.wait_until_succeeds(
            f"curl -s --max-time 10 '{NTFY}' | grep -q 'NOT mirrored'",
            timeout=240,
        )
        # The designed decoupling: sync failure is an alert, never an
        # unhealthy wiki (the healthcheck measures the LOOP, and the server
        # never depended on Forgejo at all).
        for c in ["silverbullet", "silverbullet_gitsync"]:
            health = services_vm.succeed(
                f"docker inspect {c} --format '{{{{.State.Health.Status}}}}'"
            ).strip()
            assert health == "healthy", f"{c} went {health} on a dead remote"
  '';
}
