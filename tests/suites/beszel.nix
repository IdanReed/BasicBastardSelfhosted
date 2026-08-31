# Beszel suite — hand-written, because the generic `./tests/run.sh stack beszel`
# harness cannot run this stack at all: mk-stack-suite asserts every container
# is `running`, and beszel-init is a one-shot that must exit.
#
# The organising idea: EVERY signal Beszel offers about itself is a lie, in a
# different way, and the suite exists to assert around them.
#
#   - the agent's own healthcheck stats /dev/shm/beszel_health and fails only
#     if its mtime is over 91s old — and the connection manager touches that
#     file every 90s WHETHER OR NOT it has ever reached a hub. Subtest
#     "the agent's healthcheck lies" proves this with a second agent pointed at
#     a dead address; it goes `healthy` having never connected to anything.
#   - the hub's healthcheck short-circuits before the app is constructed. It
#     proves the listener answers and nothing else — not the database, not
#     migrations, not whether a single system is reporting.
#   - a WRONG `FILESYSTEM` does not fail: the agent logs one WARN, reports
#     `healthy`, and publishes `d: 0` forever (finding #44). A monitoring stack
#     that silently reports zero disk usage is worse than none.
#
# So the only honest signal is hub-side — the `systems` row's status and the
# `system_stats` payload — and that is what this suite asserts.
#
# Genuinely under test:
#   - 🚨 **The key/token triangle end to end.** beszel-init seeds the hub's
#     ed25519 identity from .sops.env; the hub signs the agent's token with it;
#     the agent verifies that signature against KEY. Asserted positively (the
#     system reaches status `up`) and negatively (a wrong KEY produces
#     `invalid signature`, loudly, rather than a silent non-report).
#   - 🚨 **Disk numbers are real, not zero.** Root `d > 0` proves FILESYSTEM is
#     right; the /extra-filesystems entries prove the empty-marker-directory
#     design actually reports the tiers.
#   - 🚨 **Both tiers survive registration.** agent/disk.go drops a filesystem
#     whose key collides with one already registered — silently, with no log.
#     This VM therefore gives /mnt/fast and /mnt/slow SEPARATE block devices,
#     as the real host has; on a shared device one tier would just vanish from
#     the dashboard.
#   - 🚨 **config.yml is declarative AND destructive.** SyncSystems deletes
#     every system row not present, on every hub start. Pinned deliberately,
#     because it means renaming a system silently discards its history.
#   - **beszel-init is idempotent**, and **fails closed** without its secret
#     rather than letting the hub generate an unrecoverable identity.
#   - **10452 is unreachable from another machine.**
#
# Documented gaps:
#   - **Forward auth.** Needs the VPS outpost. The Caddyfile's `import
#     protected` for this vhost is covered by auth-column-parity and
#     forward-auth-coverage statically.
#   - **Alerting.** Beszel's own notification path is not exercised; nothing
#     here crosses a threshold.
#   - **The fingerprint-vs-re-image hazard.** The agent's fingerprint is
#     sha256 of the machine-id, so a re-image makes the hub reject a
#     previously-pinned agent. The mitigation (fingerprint on the DATA disk) is
#     asserted structurally — the file exists under /mnt/fast — but the failure
#     itself needs two boots with different machine-ids to reproduce.

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
    images."alpine_3_21"
    images."henrygd_beszel_0_18_8"
    images."henrygd_beszel-agent_0_18_8"
  ];

  fixture = ../fixtures/beszel.sops.env;

  seedSrv = pkgs.runCommand "srv-seed-beszel" { } ''
    mkdir -p $out/stacks/beszel
    cp -r ${../../stacks/beszel}/. $out/stacks/beszel/
    chmod -R u+w $out/stacks/beszel
    # A developer's locally-decrypted plaintext .env is gitignored but would
    # still be captured by cp -r into the world-readable store.
    rm -f $out/stacks/beszel/.env
    rm -f $out/stacks/beszel/.sops.env.example $out/stacks/beszel/.sops.env
    cp ${fixture} $out/stacks/beszel/.sops.env
  '';
in
pkgs.testers.runNixOSTest {
  name = "beszel";

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

        # 🚨 TWO EXTRA DISKS, and this is the whole reason this suite does not
        # use the tmpfs arrangement every other stack suite uses.
        #
        # registerFilesystemStats keys each filesystem by its device basename
        # and, on a collision, `return "", nil, false` — the second filesystem
        # is DROPPED with no log line and no error. Two tmpfs mounts are both
        # device "tmpfs", so /mnt/fast and /mnt/slow would collapse into one
        # entry and the suite would "pass" while asserting half of what it
        # claims to. Real block devices reproduce the host, where the tiers are
        # genuinely separate disks.
        # 🚨 DIFFERENT SIZES, and that is not cosmetic. The agent runs
        # pruneDuplicateRootExtraFilesystems (upstream #1428), which DELETES
        # any extra filesystem whose total AND used bytes match root's within
        # a 16 MB tolerance. Two freshly-formatted 1024 MB disks are
        # byte-identical, so the slow tier was silently pruned and the payload
        # arrived with no `efs` at all — see finding #49. Real tiers differ in
        # size, and so do these.
        virtualisation.emptyDiskImages = [
          1024
          2048
        ];

        virtualisation.fileSystems = {
          "/srv" = {
            device = "tmpfs";
            fsType = "tmpfs";
            options = [ "mode=0755" ];
          };
          "/mnt/fast" = {
            device = "/dev/vdb";
            fsType = "ext4";
            autoFormat = true;
          };
          "/mnt/slow" = {
            device = "/dev/vdc";
            fsType = "ext4";
            autoFormat = true;
          };
        };

        systemd.tmpfiles.rules = [
          "d /srv/stacks 0755 1000 1000 -"
          "d /var/lib/sops-nix 0700 root root -"
          "d /mnt/fast/beszel 0755 root root -"
          "d /mnt/fast/beszel-agent 0755 root root -"
          "d /mnt/fast/beszel-agent/fsprobe 0755 root root -"
          "d /mnt/slow/beszel-fsprobe 0755 root root -"
        ];

        systemd.services.seed-srv = {
          description = "Seed /srv with the beszel stack (test only)";
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

    BZ = "docker compose -f /srv/stacks/beszel/compose.yaml -p beszel"
    BASE = "http://127.0.0.1:10452"
    EMAIL = "test-beszel@example.invalid"
    PASSWORD = "test_beszel_password_not_secret"
    TOKEN_UUID = "8d1f708c-cb90-4b11-bd98-4d85dd15d359"

    HUB_IMG = "henrygd/beszel:0.18.8"
    AGENT_IMG = "henrygd/beszel-agent:0.18.8"
    # A real ed25519 public key from a DIFFERENT pair than the fixture's.
    WRONG_KEY = (
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFA67/qIg2OWNRRI5nfPUozK8baEUdjtN5YX8Iw6H8bf wrong-pair"
    )

    def api(path, token, method="GET", body=None):
        cmd = (
            f"curl -fsS --max-time 30 -X {method} "
            f"-H 'Authorization: {token}' "
        )
        if body is not None:
            cmd += "-H 'Content-Type: application/json' -d '" + body + "' "
        cmd += f"'{BASE}{path}'"
        return json.loads(services_vm.succeed(cmd))

    def superuser_token():
        raw = services_vm.succeed(
            "curl -fsS --max-time 30 -X POST "
            f"'{BASE}/api/collections/_superusers/auth-with-password' "
            "-H 'Content-Type: application/json' "
            "-d '" + json.dumps({"identity": EMAIL, "password": PASSWORD}) + "'"
        )
        return json.loads(raw)["token"]

    def dump_diag():
        for label, cmd in [
            ("compose ps", f"{BZ} ps -a"),
            ("init logs", "docker logs beszel-init 2>&1 | tail -30"),
            ("hub logs", "docker logs beszel 2>&1 | tail -40"),
            ("agent logs", "docker logs beszel-agent 2>&1 | tail -40"),
            ("data dir", "ls -la /mnt/fast/beszel"),
            ("mounts", "findmnt -no SOURCE,TARGET /mnt/fast /mnt/slow"),
        ]:
            print(f"--- {label} ---")
            print(services_vm.execute(cmd)[1])

    start_all()

    services_vm.wait_for_unit("multi-user.target")
    services_vm.wait_for_unit("docker-network-homelab.service")
    services_vm.wait_for_unit("load-test-images.service")

    try:
        with subtest("the tiers really are separate devices"):
            # If this ever regresses to one device, the two-tier assertion
            # below becomes vacuous rather than failing — see the
            # emptyDiskImages comment.
            fast = services_vm.succeed("findmnt -no SOURCE /mnt/fast").strip()
            slow = services_vm.succeed("findmnt -no SOURCE /mnt/slow").strip()
            assert fast != slow, f"both tiers are on {fast}"

        with subtest("the fixture .sops.env decrypted to a 0600 .env"):
            # NOT wait_for_unit: decrypt-sops-envs is a transient oneshot
            # with no RemainAfterExit (a minutely timer re-fires it), so
            # waiting on the UNIT races its inactive-after-success state and
            # fails with "inactive and there are no pending jobs". The
            # artifact it must produce is the synchronisation point —
            # mk-stack-suite already documents this; this suite did not
            # follow it.
            services_vm.wait_until_succeeds(
                "test -s /srv/stacks/beszel/.env", timeout=90
            )
            services_vm.succeed("test -f /srv/stacks/beszel/.env")
            mode = services_vm.succeed(
                "stat -c %a /srv/stacks/beszel/.env"
            ).strip()
            assert mode == "600", f".env is mode {mode}, expected 600"

        with subtest("the stack comes up: init -> hub -> agent"):
            # No `--wait`: beszel-init is a one-shot that must EXIT, and
            # `up --wait` fails on an exited service (finding #39). The
            # depends_on chain — init service_completed_successfully, then hub,
            # then agent service_healthy — is what orders this, and asserting
            # the end state below is what proves the chain ran.
            services_vm.succeed(f"{BZ} up -d")
            services_vm.wait_until_succeeds(
                f"curl -fsS -o /dev/null --max-time 10 {BASE}/api/health",
                timeout=180,
            )
            services_vm.wait_until_succeeds(
                "test \"$(docker inspect -f '{{.State.Health.Status}}' "
                "beszel-agent)\" = healthy",
                timeout=180,
            )

        with subtest("beszel-init seeded the hub identity, not the hub itself"):
            # The distinction matters: a hub that generates its own key writes
            # NO .pub and keeps the public half in memory, so the matching KEY
            # is unrecoverable afterwards. The proof that the SEEDED key is the
            # one in use is the agent connecting at all — see below — but the
            # file and its mode are worth pinning too.
            mode = services_vm.succeed(
                "stat -c %a /mnt/fast/beszel/id_ed25519"
            ).strip()
            assert mode == "600", f"hub key is mode {mode}, expected 600"
            cfg = services_vm.succeed("cat /mnt/fast/beszel/config.yml")
            assert TOKEN_UUID in cfg, cfg
            assert "services-vm" in cfg, cfg
            logs = services_vm.succeed("docker logs beszel-init 2>&1")
            assert "CHANGE: wrote /beszel_data/id_ed25519" in logs, logs

        with subtest("beszel-init is idempotent (a second run changes nothing)"):
            # Every Arcane redeploy reruns it. House rule: a second run against
            # unchanged input logs ZERO "CHANGE:" lines.
            out = services_vm.succeed(f"{BZ} run --rm --no-deps beszel-init 2>&1")
            assert "CHANGE:" not in out, out
            assert "hub key already correct" in out, out
            assert "systems config already correct" in out, out

        with subtest("🚨 the system reports UP hub-side — the only honest signal"):
            # Everything else in this stack reports healthy regardless. This is
            # the assertion that actually proves the key/token triangle closed:
            # the agent presented TOKEN, the hub signed it with the SEEDED
            # ed25519 key, and the agent verified that signature against KEY.
            token = superuser_token()
            services_vm.wait_until_succeeds(
                f"curl -fsS --max-time 30 -H 'Authorization: {token}' "
                f"'{BASE}/api/collections/systems/records' "
                "| jq -e '.items[0].status == \"up\"' >/dev/null",
                timeout=180,
            )
            systems = api("/api/collections/systems/records", token)["items"]
            assert len(systems) == 1, systems
            assert systems[0]["name"] == "services-vm", systems[0]

        with subtest("🚨 disk numbers are real, and both tiers survived"):
            token = superuser_token()
            # Wait for a stats row that has the root disk populated. `d` is
            # total GB; a wrong FILESYSTEM yields 0 here with no other symptom
            # (finding #44), so this is the assertion that catches it.
            services_vm.wait_until_succeeds(
                f"curl -fsS --max-time 30 -H 'Authorization: {token}' "
                f"'{BASE}/api/collections/system_stats/records"
                "?sort=-created&perPage=1' "
                "| jq -e '.items[0].stats.d > 0' >/dev/null",
                timeout=240,
            )
            rec = api(
                "/api/collections/system_stats/records?sort=-created&perPage=1",
                token,
            )["items"][0]
            stats = rec["stats"]
            assert stats["d"] > 0, stats
            # NOT `du > 0`: a freshly formatted ext4 rounds to 0.00 GB used,
            # and "no data yet" is not a defect. `d` is the assertion that
            # matters — it is the one a wrong FILESYSTEM zeroes.

            # The empty-marker-directory design: statfs answers for the whole
            # containing filesystem, so an empty dir on each tier reports the
            # tier without exposing its contents. If that assumption were ever
            # wrong this is where it fails.
            #
            # ⚠ NOT `len(efs) == 2`. Whichever device FILESYSTEM names gets
            # PROMOTED out of `efs` and becomes the root entry — the fixture
            # says vdb, so /mnt/fast lands in `d` and only /mnt/slow stays in
            # `efs`. Counting efs alone would therefore assert the wrong thing
            # in one configuration and be trivially satisfiable in the other.
            # What matters is that BOTH tiers are represented somewhere with a
            # real size.
            efs = stats.get("efs") or {}
            sizes = [("root", stats.get("d") or 0)] + [
                (dev, e.get("d") or 0) for dev, e in efs.items()
            ]
            nonzero = [(k, v) for k, v in sizes if v > 0]
            assert len(nonzero) >= 2, (
                f"expected both storage tiers to report a size, got {sizes!r}"
            )

        with subtest("🚨 BOTH tiers registered — neither was silently dropped"):
            # agent/disk.go's registerFilesystemStats keys each filesystem by
            # its device basename and, on a collision, `return "", nil, false`:
            # the second is dropped with NO log line and NO error (finding
            # #46). The registration log is the only place both mounts can be
            # observed by name, and a dropped one never appears — so this, not
            # a count of the payload, is the honest assertion.
            logs = services_vm.succeed("docker logs beszel-agent 2>&1")
            # 🚨 The second way a tier disappears, and the one that actually
            # fired here (finding #49): pruneDuplicateRootExtraFilesystems
            # deletes any extra filesystem whose total AND used bytes match
            # root's within 16 MB. It is a heuristic on SIZE, not on identity,
            # so two same-sized tiers at similar fill levels lose one of them.
            assert "Ignoring duplicate FS" not in logs, (
                "a storage tier was pruned as a duplicate of root — it looks "
                "identical by size and usage, and a tier you are not shown "
                "looks exactly like a tier that is fine.\n" + logs
            )
            for mount in ["/extra-filesystems/fast", "/extra-filesystems/slow"]:
                assert f"mount={mount}" in logs, (
                    f"{mount} was never registered. If both tiers share a "
                    f"device basename the second is dropped silently — on the "
                    f"host that means a whole storage tier vanishing from the "
                    f"dashboard, which looks exactly like a tier that is fine."
                    f"\n{logs}"
                )

        with subtest("🚨 FILESYSTEM names a device that exists (finding #44)"):
            # A wrong value does not fail: one WARN, then `healthy` and a 0 GB
            # disk forever. The warning IS the signal, so assert its absence
            # rather than trying to distinguish a real zero from a fake one.
            logs = services_vm.succeed("docker logs beszel-agent 2>&1")
            assert "Partition details not found" not in logs, (
                "FILESYSTEM names a device with no mount the agent can see; "
                "root disk stats will be reported as 0 forever.\n" + logs
            )
            assert "Root I/O device not detected" not in logs, logs

        with subtest("🚨 10452 is unreachable from another machine"):
            ip = services_vm.succeed(
                "ip -4 -o addr show eth1 | awk '{print $4}' | cut -d/ -f1"
            ).strip()
            outsider.wait_for_unit("network.target")
            outsider.fail(f"curl -s --max-time 10 http://{ip}:10452/api/health >/dev/null")
            outsider.succeed(f"ping -c1 -W5 {ip} >/dev/null")

        with subtest("🚨 a WRONG key fails LOUDLY, not silently"):
            # The failure mode this guards is a mismatched pair being invisible.
            # A throwaway agent with a key from a different pair must say so.
            services_vm.succeed(
                "docker run -d --name bkg-bez-badkey --network host "
                f"-e HUB_URL={BASE} -e DISABLE_SSH=true -e DOCKER_HOST= "
                f"-e TOKEN={TOKEN_UUID} "
                # A REAL key from a different pair, not a garbage string:
                # loadPublicKeys log.Fatal()s on anything unparseable, which
                # would exit before the signature check and prove nothing.
                "-e KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFA67/qIg2OWNRRI5nfPUozK8baEUdjtN5YX8Iw6H8bf wrong-pair' "
                f"{AGENT_IMG} >/dev/null"
            )
            services_vm.wait_until_succeeds(
                "docker logs bkg-bez-badkey 2>&1 | grep -qi 'signature'",
                timeout=120,
            )
            services_vm.succeed("docker rm -f bkg-bez-badkey >/dev/null")

        with subtest("🚨 the agent's healthcheck lies (this is why we ask the hub)"):
            # Pointed at a dead address, having never connected to anything,
            # `/agent health` still passes: it stats /dev/shm/beszel_health and
            # fails only if the mtime is over 91s old, and the connection
            # manager touches that file every 90s regardless of whether a hub
            # was ever reached. Verified locally against 0.18.8 before this was
            # written.
            #
            # ⚠ NOT `docker run --health-cmd`. That flag is ALWAYS CMD-SHELL —
            # docker wraps it in /bin/sh -c — and this image is FROM scratch
            # with no shell, so the probe fails with "stat /bin/sh: no such
            # file or directory" and the container goes `unhealthy` for a
            # reason that has nothing to do with what is being tested. (That is
            # a real trap for this fleet: gatus, beszel and rmfakecloud are all
            # scratch images. Compose's `test: ["CMD", ...]` is exec form and
            # does not have this problem, which is what the stack uses.)
            # `docker exec` is exec form, so it runs the binary directly.
            services_vm.succeed(
                "docker run -d --name bkg-bez-nohub --network host "
                "-e HUB_URL=http://127.0.0.1:1 -e DISABLE_SSH=true "
                f"-e DOCKER_HOST= -e TOKEN={TOKEN_UUID} "
                f"-e KEY='{WRONG_KEY}' "
                f"{AGENT_IMG} >/dev/null"
            )
            # Past the 91s staleness window on purpose: below it the file is
            # merely fresh from startup and the assertion would be trivial.
            services_vm.sleep(100)
            services_vm.succeed("docker exec bkg-bez-nohub /agent health")
            logs = services_vm.succeed("docker logs bkg-bez-nohub 2>&1")
            assert "WebSocket connected" not in logs, (
                "the negative control connected to something — it is supposed "
                "to be pointed at a dead address"
            )
            services_vm.succeed("docker rm -f bkg-bez-nohub >/dev/null")

        with subtest("🚨 config.yml is declarative AND destructive"):
            # SyncSystems deletes every system row not present in config.yml on
            # every hub start. That is the property this fleet wants, but it
            # also means renaming a system silently discards its history — so
            # it is pinned here rather than left as a comment.
            services_vm.succeed(
                "sed -i 's/name: services-vm/name: renamed-vm/' "
                "/mnt/fast/beszel/config.yml"
            )
            services_vm.succeed(f"{BZ} restart beszel")
            services_vm.wait_until_succeeds(
                f"curl -fsS -o /dev/null --max-time 10 {BASE}/api/health",
                timeout=120,
            )
            token = superuser_token()
            services_vm.wait_until_succeeds(
                f"curl -fsS --max-time 30 -H 'Authorization: {token}' "
                f"'{BASE}/api/collections/systems/records' "
                "| jq -e '[.items[].name] == [\"renamed-vm\"]' >/dev/null",
                timeout=120,
            )

        with subtest("🚨 beszel-init fails closed without its secret"):
            # A hub allowed to start with no seeded key generates its own,
            # writes no .pub, and keeps the public half in memory — the pair
            # becomes unrecoverable. Refusing up front is the backrest
            # missing-key gate applied to a different secret.
            services_vm.succeed("mkdir -p /tmp/emptydata")
            rc, out = services_vm.execute(
                "docker run --rm --name bkg-bez-nokey "
                "-v /srv/stacks/beszel/beszel-init.sh:/init.sh:ro "
                "-v /tmp/emptydata:/beszel_data "
                "alpine:3.21 /bin/sh /init.sh 2>&1"
            )
            assert rc != 0, f"init exited 0 with no secret:\n{out}"
            assert "HUB_SSH_KEY_B64 is empty" in out, out

        with subtest("🚨 an invalid key is rejected before the hub sees it"):
            rc, out = services_vm.execute(
                "docker run --rm --name bkg-bez-badb64 "
                "-e HUB_SSH_KEY_B64=not-base64-at-all "
                f"-e TOKEN={TOKEN_UUID} "
                "-v /srv/stacks/beszel/beszel-init.sh:/init.sh:ro "
                "-v /tmp/emptydata:/beszel_data "
                "alpine:3.21 /bin/sh /init.sh 2>&1"
            )
            assert rc != 0, f"init accepted garbage:\n{out}"
            assert "HUB_SSH_KEY_B64" in out, out
    except Exception:
        dump_diag()
        raise
  '';
}
