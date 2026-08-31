# Notes/Sync suite: rmfakecloud, Syncthing, and the two one-shots that
# provision them.
#
# Hand-written because two of the four containers are `restart: "no"` one-shots
# (mk-stack-suite asserts every container is running) and because the most
# important assertion here is a POSITIVE one about a port that is deliberately
# NOT loopback-bound — the inverse of what the generic suite checks.
#
# Genuinely under test:
#   - **The bare 22000 publish is real, and the loopback ones are real.** This
#     is the fleet's only intentional 0.0.0.0 publish: BEP peers must dial this
#     host, and the safety argument is that BEP is mutually authenticated by
#     device certificate before it does anything. The suite asserts the
#     outsider CAN reach 22000 and CANNOT reach 10200 or 10201, so the
#     exemption is proven rather than assumed. (Note the generic suite would go
#     green either way — a bare publish satisfies both its loopback probe and
#     its outsider probe, because the outsider is blocked by the firewall, not
#     by the binding. That is exactly why this is written by hand.)
#   - **The create-once window is closed.** rmfakecloud's first login CREATES
#     an admin from whatever credentials arrive, with no switch to disable it.
#     The suite proves the real admin exists AND that a second, unknown email
#     no longer gets an account — which is what "the window closed" means.
#   - **The uid trap that fails silently.** Syncthing's entrypoint chown is
#     non-recursive and swallows its own error, so a wrongly-owned tree yields
#     a HEALTHY container with an errored folder and no crash. The suite
#     asserts the folder's own status is error-free, not merely that the
#     container is up.
#   - **The device identity survives a reboot.** key.pem IS the device ID;
#     regenerating it makes every peer treat this host as a stranger. The suite
#     records myID before the reboot and requires the same value after.
#   - the four egress switches really are off in the running config, which is
#     what makes an offline run quiet and a production tailnet deployment
#     sensible.
#   - init idempotence: a redeploy logs zero CHANGE lines.
#
# Documented gaps (a green run covers NONE of these):
#   - **Any actual synchronisation.** One Syncthing with no peers cannot sync;
#     adding a second node to the test network would prove BEP works but not
#     that the tablet does, and the tablet is the point.
#   - **The reMarkable.** No tablet, so none of /sync/v*, /document-storage/*
#     or the notebook format is exercised. What is proven is that the HTTP
#     surface those routes live on is up and that the admin can authenticate.
#   - **Syncthing's GUI forward auth.** That hop needs the VPS outpost; the
#     suite hits the API with the key instead.
#   - **The `STORAGE_URL` contract.** It must be https with no port for tablet
#     software >= 3.15, which cannot be checked without a tablet — the suite
#     asserts the value is shaped correctly and nothing more.

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
    images."ddvk_rmfakecloud_0_0_31"
    images."syncthing_syncthing_2_1_3"
    images."python_3_13-alpine" # notes-sync-init
  ];

  seedSrv = pkgs.runCommand "srv-seed-notes-sync" { } ''
    mkdir -p $out/stacks/notes-sync
    cp -r ${../../stacks/notes-sync}/. $out/stacks/notes-sync/
    chmod -R u+w $out/stacks/notes-sync
    # The working-tree cp -r can capture a developer's locally-decrypted
    # plaintext .env (gitignored on purpose) in the world-readable store.
    rm -f $out/stacks/notes-sync/.env
    rm -f $out/stacks/notes-sync/.sops.env.example
    cp ${../fixtures/notes-sync.sops.env} $out/stacks/notes-sync/.sops.env
  '';
in
pkgs.testers.runNixOSTest {
  name = "notes-sync";

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
            memoryMB = 3072;
            diskMB = 12288;
          })
          (profiles.loadImages {
            inherit pkgs;
            images = stackImages;
            beforeUnits = [ "multi-user.target" ];
          })
        ];

        systemd.services.bootstrap-arcane.wantedBy = lib.mkForce [ ];

        virtualisation.cores = lib.mkForce 2;

        # 22000 is published on 0.0.0.0 in production and the host firewall is
        # what keeps it tailnet-only. The suite asserts the outsider CAN reach
        # it, so the port has to be open here — this mirrors what
        # `trustedInterfaces = ["tailscale0"]` achieves in production, where
        # the outsider would be a tailnet peer rather than an off-tailnet host.
        networking.firewall.allowedTCPPorts = [ 22000 ];
        networking.firewall.allowedUDPPorts = [ 22000 ];

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
          # The SAME set and ownership production declares in
          # nixos/hardware-configuration.nix. All 1000:1000 — rmfakecloud
          # cannot chown anything (FROM scratch, no entrypoint) and syncthing's
          # chown is non-recursive and swallows its failure.
          "d /mnt/fast/rmfakecloud 0755 1000 1000 -"
          "d /mnt/fast/rmfakecloud/data 0755 1000 1000 -"
          "d /mnt/fast/syncthing 0755 1000 1000 -"
          "d /mnt/fast/syncthing/config 0755 1000 1000 -"
          "d /mnt/fast/vault 0755 1000 1000 -"
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
            mkdir -p /srv/stacks
            cp -r --no-preserve=mode ${seedSrv}/stacks/. /srv/stacks/
            chown -R 1000:1000 /srv/stacks
          '';
        };

        environment.systemPackages = with pkgs; [
          docker-compose
          jq
        ];
      };

    outsider = { };
  };

  testScript = ''
    import json
    import shlex

    NS = "docker compose -f /srv/stacks/notes-sync/compose.yaml -p notes-sync"
    RM = "http://127.0.0.1:10200"
    ST = "http://127.0.0.1:10201"
    STCFG = "/mnt/fast/syncthing/config"

    # Fixture values from tests/fixtures/notes-sync.sops.env.
    RM_ADMIN = "rmadmin@test.invalid"
    RM_PASS = "test_rmfakecloud_password_not_secret"
    ST_KEY = "test_syncthing_api_key_not_secret_00000000000000000000"

    def diag(label):
        print("=== diagnostics: " + label + " ===")
        for cmd in [
            "docker ps -a",
            "docker logs rmfakecloud 2>&1 | tail -60",
            "docker logs syncthing 2>&1 | tail -60",
            "docker logs syncthing_generate 2>&1 | tail -30",
            "docker logs notes_sync_init 2>&1 | tail -40",
            "ls -la /mnt/fast/rmfakecloud/data /mnt/fast/syncthing/config "
            "/mnt/fast/vault 2>&1",
            "df -h /var/lib/docker /mnt; free -m",
        ]:
            print("--- " + cmd)
            print(services_vm.execute(cmd)[1])

    def st(path, method="GET"):
        out = services_vm.succeed(
            f"curl -sf --max-time 30 -X {method} "
            f"-H {shlex.quote('X-API-Key: ' + ST_KEY)} {shlex.quote(ST + path)}"
        )
        return json.loads(out) if out.strip() else None

    def rm_login(email, password):
        """Returns (status, body). Deliberately not -f: 401 is a real answer."""
        out = services_vm.succeed(
            "curl -sS -o /tmp/rmbody -w '%{http_code}' --max-time 30 "
            "-X POST -H 'Content-Type: application/json' "
            f"-d {shlex.quote(json.dumps({'email': email, 'password': password}))} "
            f"{RM}/ui/api/login"
        ).strip()
        body = services_vm.succeed("cat /tmp/rmbody")
        return int(out), body.strip()

    start_all()

    # -----------------------------------------------------------------------
    # boot chain + decrypt
    # -----------------------------------------------------------------------
    with subtest("decrypt-sops-envs produced a 0600 .env owned by arcane's uid"):
        services_vm.wait_for_unit("multi-user.target")
        services_vm.wait_for_unit("docker-network-homelab.service")
        services_vm.wait_until_succeeds(
            "test -s /srv/stacks/notes-sync/.env", timeout=120
        )
        stat = services_vm.succeed(
            "stat -c '%a %u:%g' /srv/stacks/notes-sync/.env"
        ).strip()
        assert stat == "600 1000:1000", f".env is {stat}, expected 600 1000:1000"
        for k in ["JWT_SECRET_KEY", "RMFAKECLOUD_ADMIN_EMAIL",
                  "RMFAKECLOUD_ADMIN_PASSWORD", "STGUIAPIKEY",
                  "ST_GUI_USER", "ST_GUI_PASSWORD"]:
            services_vm.succeed(f"grep -q '^{k}=.' /srv/stacks/notes-sync/.env")

    services_vm.wait_for_unit("load-test-images.service")

    # -----------------------------------------------------------------------
    # the stack comes up
    # -----------------------------------------------------------------------
    with subtest("compose up brings the long-lived containers healthy"):
        try:
            services_vm.succeed(f"{NS} up -d --wait --wait-timeout 900 rmfakecloud syncthing")
        except Exception:
            diag("compose up failed")
            raise

    with subtest("syncthing_generate created the device identity"):
        rc = services_vm.succeed(
            "docker inspect --format '{{.State.ExitCode}}' syncthing_generate"
        ).strip()
        assert rc == "0", f"syncthing_generate exited {rc}"
        for f in ["config.xml", "cert.pem", "key.pem"]:
            services_vm.succeed(f"test -f {STCFG}/{f}")
        # Pre-owned by tmpfiles, NOT by the container: the entrypoint's chown
        # is non-recursive and `|| true`.
        owner = services_vm.succeed(f"stat -c '%u:%g' {STCFG}/key.pem").strip()
        assert owner == "1000:1000", f"key.pem is {owner}, expected 1000:1000"

    with subtest("rmfakecloud's HTTP surface is up — what its healthcheck cannot prove"):
        # The container probe is `/rmfakecloud-docker listusers`, which proves
        # the data directory is readable and nothing else: the image is FROM
        # scratch and has no curl, wget or shell to reach /health with.
        code = int(services_vm.succeed(
            f"curl -s -o /dev/null -w '%{{http_code}}' --max-time 30 {RM}/health"
        ).strip())
        assert code == 200, f"GET /health returned {code}"

    with subtest("rmfakecloud runs as uid 1000, not root"):
        # A decision, not a default: Windmill later mounts this tree read-only
        # as uid 1000, and a root-owned notebook tree would make that scan
        # silently see nothing. Changing it later means chowning every notebook.
        out = services_vm.succeed(
            "docker inspect --format '{{.Config.User}}' rmfakecloud"
        ).strip()
        assert out == "1000:1000", f"rmfakecloud runs as {out!r}"
        owner = services_vm.succeed(
            "stat -c '%u:%g' /mnt/fast/rmfakecloud/data"
        ).strip()
        assert owner == "1000:1000", f"data dir is {owner}"

    # -----------------------------------------------------------------------
    # provisioning
    # -----------------------------------------------------------------------
    with subtest("notes-sync-init exited 0 and reported its changes"):
        services_vm.wait_until_succeeds(
            "docker inspect --format '{{.State.Status}}' notes_sync_init "
            "| grep -qx exited",
            timeout=600,
        )
        rc = services_vm.succeed(
            "docker inspect --format '{{.State.ExitCode}}' notes_sync_init"
        ).strip()
        assert rc == "0", f"notes_sync_init exited {rc}"
        logs = services_vm.succeed("docker logs notes_sync_init 2>&1")
        assert "CHANGE: created the first rmfakecloud admin" in logs, logs
        assert "CHANGE: created syncthing folder 'vault'" in logs, logs
        assert "done" in logs, logs

    with subtest("the real admin authenticates"):
        code, body = rm_login(RM_ADMIN, RM_PASS)
        assert code == 200, f"login returned {code}: {body[:300]}"
        assert body.strip().strip('"'), "login returned an empty token"

    with subtest("the create-once window is CLOSED — the assertion that matters"):
        # rmfakecloud creates an admin from the FIRST login on an empty store,
        # with no switch to disable it. Once a user exists that path is gone,
        # and proving it is gone is the only way to know the window ever
        # closed. An unknown email must now be rejected, not enrolled.
        code, body = rm_login("someone-else@test.invalid", "whatever")
        assert code >= 400, (
            f"an unknown email got {code} rather than a rejection: {body[:300]}. "
            "The first-login-creates-admin path is still open, which means "
            "anything that reaches this port owns the instance."
        )

    with subtest("registration is closed"):
        # RegistrationOpen is unset, so register() aborts with a bare 400
        # BEFORE its client-IP check ever runs. (The 403 'Registrations are
        # closed' path needs OPEN_REGISTRATION=true, which this stack never
        # sets — so 400 is the assertion that matches the shipped config.)
        code = int(services_vm.succeed(
            "curl -s -o /dev/null -w '%{http_code}' --max-time 30 -X POST "
            "-H 'Content-Type: application/json' "
            "-d '{\"email\":\"nobody@test.invalid\",\"password\":\"x\"}' "
            f"{RM}/ui/api/register"
        ).strip())
        assert code == 400, f"register returned {code}, expected 400"

    with subtest("the four egress switches are off in the RUNNING config"):
        # Asserted against the live config rather than the init script's
        # intent: these live in config.xml, not the environment, so nothing
        # else would catch a PATCH that silently did not apply.
        opts = st("/rest/config/options")
        for k, want in [("globalAnnounceEnabled", False),
                        ("relaysEnabled", False),
                        ("natEnabled", False),
                        ("localAnnounceEnabled", False),
                        ("urAccepted", -1)]:
            assert opts.get(k) == want, f"{k} is {opts.get(k)!r}, expected {want!r}"

    with subtest("the vault folder exists and is NOT errored"):
        # The silent-failure assertion. Syncthing's entrypoint chown is
        # non-recursive with `|| true`, so a wrongly-owned tree gives a healthy
        # container that marks the folder errored on first scan — finding #14
        # with the crash-loop replaced by silence, which is worse.
        folders = {f["id"]: f for f in st("/rest/config/folders")}
        assert "vault" in folders, f"folders are {sorted(folders)}"
        assert folders["vault"]["path"] == "/var/syncthing/vault", folders["vault"]
        services_vm.wait_until_succeeds(
            "curl -sf --max-time 20 "
            f"-H {shlex.quote('X-API-Key: ' + ST_KEY)} "
            f"'{ST}/rest/db/status?folder=vault' | grep -q '\"state\"'",
            timeout=180,
        )
        status = st("/rest/db/status?folder=vault")
        assert status.get("errors", 0) == 0, f"folder has errors: {status}"
        assert status.get("state") != "error", f"folder state is {status.get('state')}"

    with subtest("notes-sync-init is idempotent — a redeploy changes nothing"):
        services_vm.succeed("docker rm -f notes_sync_init")
        services_vm.succeed(f"{NS} up -d notes-sync-init")
        services_vm.wait_until_succeeds(
            "docker inspect --format '{{.State.Status}}' notes_sync_init "
            "| grep -qx exited",
            timeout=300,
        )
        rc = services_vm.succeed(
            "docker inspect --format '{{.State.ExitCode}}' notes_sync_init"
        ).strip()
        assert rc == "0", f"second notes_sync_init run exited {rc}"
        logs = services_vm.succeed("docker logs notes_sync_init 2>&1")
        assert "CHANGE:" not in logs, f"second run mutated something:\n{logs}"

    # -----------------------------------------------------------------------
    # publishing — one port is SUPPOSED to be reachable
    # -----------------------------------------------------------------------
    with subtest("10200 and 10201 are loopback-only; 22000 is NOT"):
        ip = services_vm.succeed(
            "ip -4 -o addr show eth1 | awk '{print $4}' | cut -d/ -f1"
        ).strip()
        outsider.wait_for_unit("network.target")
        outsider.fail(f"curl -s --max-time 10 http://{ip}:10200/health >/dev/null")
        outsider.fail(f"curl -s --max-time 10 http://{ip}:10201/ >/dev/null")
        # The POSITIVE half, and the whole reason this suite is hand-written:
        # BEP peers must be able to dial this host. A loopback publish here
        # would leave only the public relay pool, which needs egress. The
        # safety argument is that BEP is mutually authenticated by device
        # certificate — an unknown device is rejected at the TLS layer — so
        # reachability grants nothing. If this ever starts failing, the
        # loopback-binding exemption has been "fixed" and sync is broken.
        outsider.succeed(
            f"timeout 10 sh -c 'echo > /dev/tcp/{ip}/22000' 2>/dev/null "
            f"|| nc -z -w5 {ip} 22000"
        )

    # -----------------------------------------------------------------------
    # backup contract
    # -----------------------------------------------------------------------
    with subtest("the index database exists, so its backrest exclude is real"):
        # index-v2/ is WAL-mode SQLite, continuously written and fully DERIVED
        # (a rescan rebuilds it). It is excluded rather than dumped — asserting
        # it exists is what keeps the exclude from silently matching nothing
        # after an upstream layout change.
        services_vm.succeed(f"test -f {STCFG}/index-v2/main.db")

    with subtest("rmfakecloud really has no database to dump"):
        # The reason there is no sqlite_backup line: the user store is YAML and
        # notebooks are blob trees, so the /mnt/fast include set covers it
        # whole. A speculative dump line would be a permanent silent no-op.
        out = services_vm.succeed(
            "find /mnt/fast/rmfakecloud -maxdepth 3 -name '*.db' "
            "-o -maxdepth 3 -name '*.sqlite*' | head -5"
        ).strip()
        assert out == "", (
            f"rmfakecloud grew a database file: {out}. The backup contract "
            "assumes there is none — revisit backup-prepare.sh before this "
            "ships."
        )

    # -----------------------------------------------------------------------
    # durability — and the device identity in particular
    # -----------------------------------------------------------------------
    with subtest("the syncthing device ID survives a reboot"):
        before = st("/rest/system/status")["myID"]

        # shutdown()+start(), not reboot(): the driver runs qemu with
        # -no-reboot, so reboot() kills the VM.
        services_vm.shutdown()
        services_vm.start()
        services_vm.wait_for_unit("multi-user.target")
        services_vm.wait_until_succeeds(
            "test -s /srv/stacks/notes-sync/.env", timeout=180
        )
        services_vm.wait_for_unit("load-test-images.service")
        services_vm.succeed(f"{NS} up -d --wait --wait-timeout 900 rmfakecloud syncthing")

        after = st("/rest/system/status")["myID"]
        assert before == after, (
            f"device ID changed across a reboot: {before} -> {after}. key.pem "
            "was regenerated, which means every peer now treats this host as a "
            "stranger that must be re-accepted by hand."
        )
        # And the admin still authenticates, which proves JWT_SECRET_KEY came
        # from the fixture rather than being autogenerated per boot — the
        # failure mode that presents as "the tablet stopped syncing after a
        # reboot" with nothing in the logs at that moment.
        code, _body = rm_login(RM_ADMIN, RM_PASS)
        assert code == 200, f"post-reboot login returned {code}"
  '';
}
