# Backrest (heavy): the backup orchestrator's boot contract, end to end.
#
# Genuinely under test:
#   - config-init seeding config.json ONCE via config-init.sh's busybox-awk
#     substitution, from the decrypted .env — including a '$'-laden restic
#     password surviving the whole decrypt -> source -> substitute pipeline (the
#     quoting hazard CLAUDE.md warns about, proven here rather than left as
#     folklore). That this suite runs offline is itself part of the contract:
#     the script's predecessor did `apk add gettext` at boot, which no
#     network-free run could ever pass — and no network-degraded real boot
#     either.
#   - "Backrest owns the file afterwards": a re-run of config-init must leave
#     an existing config.json byte-identical
#   - the storage-box-key gate, BOTH ways: no key -> config-init fails and
#     depends_on: service_completed_successfully keeps Backrest down (the
#     fail-loudly-before-broken-backups contract in the compose comments);
#     key restored -> the stack converges again
#   - the UI published on 127.0.0.1:10002 only, verified from another host
#   - backrest and ntfy sharing the external `homelab` network, and ntfy
#     resolving by name from inside the backrest container — the path every
#     snapshot success/failure webhook takes (the old host.docker.internal
#     design failed exactly here)
#   - the whole services-VM boot chain underneath it: sops fixture decrypt,
#     docker-network-homelab, bootstrap-komodo
#
#   - the restic pipeline FOR REAL: this VM runs its own SFTP endpoint (a
#     `restic` user whose authorized key is the same test key mounted into the
#     container at the production path), and the seeded ssh_config is rewritten
#     at runtime to point Host storagebox at it. Auto-init creates an actual
#     repository over SFTP, a login with the fixture credentials triggers an
#     actual backup, and the snapshot lands in the repo. The ONLY unreal
#     element is the endpoint's address (and port 22 instead of 23) — key,
#     sftp, restic, auto-init, snapshot are all the production machinery.
#   - the outage matrix (per Idan): box down at FIRST-EVER init ->
#     crash-loop, UI down until the box appears; box down across a mere
#     RESTART of an already-initialized repo -> UI comes up fine; box lost
#     while running -> UI survives; box restored -> unattended recovery with
#     a real re-init. The fatal path is exclusive to a never-initialized
#     repo — narrower (and kinder) than first assumed, and pinned here so an
#     image bump changing the boundary fails a test.
#
# CANNOT cover, do not read a green run as covering these:
#   - Hetzner itself: the real network path, the sub-account scoping, and the
#     console-side Storage Box snapshots that make a hostile prune recoverable.
#     This is the ONLY remaining gap. backup-prepare's VPS state pull, once
#     listed here too, is now covered elsewhere: the tailnet suite runs the
#     green path (a real pull over a real tailnet, success stamped) and the
#     services suite the failure path (missing key -> loud failure ->
#     OnFailure -> ntfy).

{
  pkgs,
  lib,
  images,
  profiles,
  sopsModule,
  ...
}:

let
  # ntfy is seeded alongside backrest because it is the webhook target on the
  # shared homelab network — assertion (g) is about the two of them together.
  seededStacks = [
    "ntfy"
    "backrest"
  ];

  stackImages = [
    # The boot chain: bootstrap-komodo is wantedBy multi-user.target, so its
    # image must be loadable before the script gets control.
    images."ghcr_io_moghtech_komodo-core_2_1_0"
    images."ghcr_io_moghtech_komodo-periphery_2_1_0"
    images."ghcr_io_ferretdb_ferretdb_2_7_0"
    images."ghcr_io_ferretdb_postgres-documentdb_17-0_107_0-ferretdb-2_7_0"
    images."binwiederhier_ntfy_v2_11_0"
    images."garethgeorge_backrest_v1_9_1"
    # config-init's base image. Stock — config-init.sh uses only what alpine
    # ships (busybox sh/grep/awk), which is what lets it run at all in this
    # network-free sandbox. If the script ever grows an `apk add` again, this
    # suite failing on the first seed is the intended alarm.
    images."alpine_3_21"
  ];

  # Seeds /srv the way the real host gets it: stack-git-sync on the live
  # machine, a store copy here. The fixture .sops.env files stand in for the
  # real encrypted ones so decrypt-sops-envs.service runs for real; the
  # backrest fixture deliberately carries a single-quoted '$'-laden restic
  # password, a base64 bcrypt that actually decodes (so the API login works),
  # and a DEADMAN_URL pointing at the discard port.
  seedSrv = pkgs.runCommand "srv-seed-backrest" { } ''
    mkdir -p $out/komodo $out/stacks
    cp ${../../komodo/compose.yaml} $out/komodo/compose.yaml
    cp ${../fixtures/komodo.sops.env} $out/komodo/.sops.env

    ${lib.concatMapStringsSep "\n" (s: ''
      mkdir -p $out/stacks/${s}
      cp -r ${../../stacks + "/${s}"}/. $out/stacks/${s}/
      chmod -R u+w $out/stacks/${s}
      # The working-tree cp -r can capture a developer's locally-decrypted
      # plaintext .env (gitignored on purpose) in the world-readable store.
      rm -f $out/stacks/${s}/.env
      rm -f $out/stacks/${s}/.sops.env.example
      cp ${../fixtures + "/${s}.sops.env"} $out/stacks/${s}/.sops.env
    '') seededStacks}
  '';
in
pkgs.testers.runNixOSTest {
  name = "backrest";

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
            memoryMB = 6144;
            diskMB = 12288;
          })
          (profiles.loadImages {
            inherit pkgs;
            images = stackImages;
            beforeUnits = [ "bootstrap-komodo.service" ];
          })
          # stack-git-sync timer would fail its clone each tick (no Forgejo here).
          { systemd.timers.stack-git-sync.wantedBy = lib.mkForce [ ]; }
        ];

        # decrypt-sops-envs.service and bootstrap-komodo.service both
        # `requires = srv.mount`; backrest additionally bind-mounts /mnt/fast
        # and /mnt/slow read-only. tmpfs gives each a genuine .mount unit.
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

        # Copied from nixos/hardware-configuration.nix, which cannot be
        # imported here because it mounts real partitions by partlabel.
        systemd.tmpfiles.rules = [
          "d /srv/komodo 0755 root root -"
          "d /srv/stacks 0755 1000 1000 -"
          "d /var/lib/sops-nix 0700 root root -"
          # Volume roots the two stacks bind-mount. Pre-created rather than
          # left to docker's auto-create so ownership is deterministic.
          "d /mnt/fast/backrest 0755 root root -"
          "d /mnt/fast/backrest/config 0755 root root -"
          "d /mnt/fast/backrest/data 0755 root root -"
          "d /mnt/fast/backrest/cache 0755 root root -"
          "d /mnt/fast/ntfy 0755 root root -"
          "d /mnt/fast/ntfy/cache 0755 root root -"
          "d /mnt/fast/ntfy/lib 0755 root root -"
          # The storage-box key is NOT planted here any more: the sops
          # fixture's BACKUP_STORAGEBOX_SSH_KEY carries the committed test
          # key, and the production tmpfiles C+ rule in configuration.nix
          # copies it from /run/secrets to /var/lib/backup/storagebox_ed25519
          # as a REAL file (a symlink would dangle inside config-init's
          # /keys bind mount). The gate subtests below move it away and back,
          # which sticks because tmpfiles only re-runs at boot/activation.
        ];

        # Populate /srv before anything reads it — the stand-in for
        # stack-git-sync having already run.
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
          docker-compose
          jq
        ];

        # The stand-in storage box: a plain user on this host whose authorized
        # key is the SAME committed test key the container gets at the
        # production mount path (/root/.ssh/id_ed25519). restic's repo URI
        # ("sftp:storagebox:/home/restic") then resolves to this home
        # directory once the runtime ssh_config rewrite points Host storagebox
        # here. sshd is the production one — pubkey-only, sftp subsystem on.
        users.users.restic = {
          isNormalUser = true;
          openssh.authorizedKeys.keys = [
            (lib.removeSuffix "\n" (builtins.readFile ../keys/test-storagebox-key.pub))
          ];
        };
      };

    # Another host on the LAN. The services VM trusts tailscale0 wholesale, so
    # anything this node can reach on a non-tailnet interface is reachable
    # from the whole VLAN — which for the Backrest UI would mean browse/restore
    # access to every backed-up file behind a single password form.
    outsider = { };
  };

  testScript = ''
    import json
    import time

    NTFY = "docker compose -f /srv/stacks/ntfy/compose.yaml -p ntfy"
    BACKREST = "docker compose -f /srv/stacks/backrest/compose.yaml -p backrest"
    CONFIG = "/mnt/fast/backrest/config/config.json"
    KEY = "/var/lib/backup/storagebox_ed25519"

    def stack_diag(label):
        # wait/--wait failures six minutes into a boot are useless without
        # context; dump what docker actually did on the way out.
        print("=== diagnostics: " + label + " ===")
        for cmd in [
            "docker ps -a",
            "docker logs backrest_config_init 2>&1 | tail -40",
            "docker logs backrest 2>&1 | tail -40",
            "docker logs ntfy 2>&1 | tail -40",
            "ls -la /srv/stacks/backrest /mnt/fast/backrest/config /var/lib/backup 2>&1",
            "journalctl -u docker --no-pager -o cat | tail -30",
        ]:
            print("--- " + cmd)
            print(services_vm.execute(cmd)[1])

    def backrest_login():
        # The fixture bcrypt is a REAL hash of test_backrest_password precisely
        # so this login can happen — with garbage there, nothing could ever
        # authenticate and the whole plan/hook machinery went untested. Shared
        # by the happy-path backup and the during-outage backup below.
        token = services_vm.succeed(
            "curl -sf --max-time 10 -X POST "
            "-H 'Content-Type: application/json' "
            "-d '{\"username\":\"admin\",\"password\":\"test_backrest_password\"}' "
            "http://127.0.0.1:10002/v1.Authentication/Login | jq -r .token"
        ).strip()
        assert token and token != "null", f"login returned no token: {token!r}"
        return token

    def trigger_backup(token):
        # Server-streaming RPC: curl holds the connection until the backup
        # finishes. /mnt/fast is small tmpfs, so this is seconds. Body is
        # captured, not discarded — a connect-RPC error arrives as a JSON
        # body on a 4xx, and that body IS the diagnosis.
        return services_vm.succeed(
            "curl -s --max-time 120 -X POST "
            "-H 'Content-Type: application/json' "
            f"-H 'Authorization: Bearer {token}' "
            "-d '{\"value\":\"fast-volume\"}' "
            "-w '\\nHTTP_CODE:%{http_code}' "
            "http://127.0.0.1:10002/v1.Backrest/Backup"
        )

    start_all()

    # -----------------------------------------------------------------------
    # Boot chain
    # -----------------------------------------------------------------------
    # The same chain the services suite covers in depth; here it only has to
    # deliver a decrypted .env and the homelab network before compose runs.
    services_vm.wait_for_unit("docker-network-homelab.service")
    services_vm.wait_for_unit("bootstrap-komodo.service")
    services_vm.succeed("test -s /srv/stacks/backrest/.env")
    services_vm.succeed("test -s /srv/stacks/ntfy/.env")

    # The sops -> tmpfiles delivery chain produced the key the containers
    # mount: a REAL file (not a symlink — that would dangle inside the /keys
    # bind mount), byte-identical to the committed test key the in-VM SFTP
    # endpoint authorises. If this breaks, every later subtest fails
    # confusingly on ssh auth; fail here with the actual cause instead.
    services_vm.succeed(f"test -f {KEY} && test ! -L {KEY}")
    services_vm.succeed(f"cmp {KEY} ${../keys/test-storagebox-key}")

    # -----------------------------------------------------------------------
    # (a) ntfy first — it is the webhook target backrest's config points at
    # -----------------------------------------------------------------------
    with subtest("ntfy is up and healthy on the homelab network"):
        try:
            services_vm.succeed(NTFY + " up -d --wait --wait-timeout 180")
        except Exception:
            stack_diag("ntfy up")
            raise
        services_vm.wait_until_succeeds(
            "curl -sf --max-time 5 http://127.0.0.1:10001/v1/health "
            "| jq -e '.healthy == true'",
            timeout=60,
        )

    # -----------------------------------------------------------------------
    # (a2) point Host storagebox at this VM's own sshd
    # -----------------------------------------------------------------------
    with subtest("the seeded ssh_config is rewritten to the in-VM endpoint"):
        # The container reaches the host through the homelab bridge gateway.
        # Each sed is asserted to have matched: if the production ssh_config is
        # ever restructured, this fails loudly instead of quietly testing a
        # stale substitution — same philosophy as the Caddyfile tls swap.
        gw = services_vm.succeed(
            "docker network inspect homelab "
            "-f '{{(index .IPAM.Config 0).Gateway}}'"
        ).strip()
        assert gw, "homelab network has no gateway address"

        SSHCFG = "/srv/stacks/backrest/ssh_config"
        for pat, repl, expect in [
            (r"^\s*HostName .*", f"    HostName {gw}", f"HostName {gw}"),
            (r"^\s*Port .*", "    Port 22", "Port 22"),
            (r"^\s*User .*", "    User restic", "User restic"),
        ]:
            services_vm.succeed(f"sed -i 's|{pat}|{repl}|' {SSHCFG}")
            services_vm.succeed(f"grep -qF '{expect}' {SSHCFG}")

        # The host-key PIN must follow the endpoint the same way. Production
        # ships Hetzner's published keys in known_hosts with
        # StrictHostKeyChecking yes; this VM's sshd is the stand-in, so the
        # pin is re-pointed at it — NOT relaxed to accept-new, which would
        # stop testing that a wrong key is fatal. ssh-keyscan of the gateway
        # replaces the file wholesale; the grep asserts the scan produced
        # keys rather than an empty file (keyscan exits 0 on nothing).
        KNOWN = "/srv/stacks/backrest/known_hosts"
        services_vm.succeed(
            f"ssh-keyscan -p 22 -t rsa,ecdsa,ed25519 {gw} > {KNOWN}"
        )
        services_vm.succeed(f"grep -q 'ssh-ed25519\\|ecdsa\\|ssh-rsa' {KNOWN}")

    # -----------------------------------------------------------------------
    # (b) backrest up: config-init completes, backrest runs
    # -----------------------------------------------------------------------
    with subtest("config-init completes and backrest reaches running"):
        # --wait treats the one-shot config-init (restart: "no") as satisfied
        # once it exits 0, and depends_on: service_completed_successfully is
        # exactly the ordering under test.
        try:
            services_vm.succeed(BACKREST + " up -d --wait --wait-timeout 180")
        except Exception:
            stack_diag("backrest up")
            raise
        init_exit = services_vm.succeed(
            "docker inspect -f '{{.State.ExitCode}}' backrest_config_init"
        ).strip()
        assert init_exit == "0", f"config-init exited {init_exit}, expected 0"
        status = services_vm.succeed(
            "docker inspect -f '{{.State.Status}}' backrest"
        ).strip()
        assert status == "running", f"backrest is {status!r}, expected running"

    # -----------------------------------------------------------------------
    # (b2) auto-init created a REAL restic repository over SFTP
    # -----------------------------------------------------------------------
    with subtest("auto-init creates the restic repo through sftp + key"):
        # autoInitialize: true runs `restic init` at orchestrator start; over
        # the rewritten Host storagebox that lands in /home/restic on this VM.
        # The repo's `config` file plus keys/ appearing there proves the whole
        # production chain: mounted key -> ssh_config -> sftp -> restic.
        try:
            services_vm.wait_until_succeeds(
                "test -s /home/restic/config && test -d /home/restic/keys",
                timeout=120,
            )
        except Exception:
            stack_diag("restic auto-init")
            print(services_vm.execute("ls -laR /home/restic 2>&1 | head -30")[1])
            print(services_vm.execute(
                "journalctl -u sshd --no-pager | tail -20")[1])
            raise

    # -----------------------------------------------------------------------
    # (c) the seeded config.json
    # -----------------------------------------------------------------------
    with subtest("config.json is seeded with secrets intact"):
        services_vm.succeed(f"test -s {CONFIG}")
        # config-init chmods to 600 because the file embeds the restic
        # password — the key that decrypts every backup.
        mode = services_vm.succeed(f"stat -c '%a' {CONFIG}").strip()
        assert mode == "600", f"config.json is mode {mode}, expected 600"

        # These three positive greps are the real substitution coverage: one
        # per template variable, each asserting the fixture VALUE landed — so
        # a variable substituted to "" (what envsubst used to do silently for
        # a missing one; config-init.sh now hard-fails instead, which subtest
        # (b) would catch as a nonzero exit) cannot pass here.
        # The restic password is deliberately full of '$'. If the
        # single-quoting rule from CLAUDE.md ever stops holding through
        # decrypt -> source -> substitute, the shell expands '$t', '$tic'
        # etc. to nothing and this literal vanishes.
        services_vm.succeed(f"grep -qF 'te$t_re$tic_pa$$word' {CONFIG}")
        # base64(bcrypt(test_backrest_password)) — base64 because backrest
        # decodes passwordBcrypt before comparing; subtest (h) proves it by
        # actually logging in with the plaintext.
        services_vm.succeed(
            f"grep -qF JDJhJDEwJEZHclJqRzBaRkNhMmt1UGFiT1hGbWVRQm9VdlpUQnFRVHpjTlNCY3dITGpXNDhid0NKdHNT {CONFIG}"
        )
        services_vm.succeed(
            f"grep -qF 'http://127.0.0.1:9/deadman-test-endpoint' {CONFIG}"
        )
        # No placeholder may survive into the config. The greps above cover
        # the variables the template uses today; this catches the awk loop in
        # config-init.sh regressing on one they don't (a new variable, an
        # unanchored-match bug) — it proves substitution ran to completion,
        # not that every value was present (the script's own non-empty check
        # owns that).
        dollar_brace = "$" + "{"
        services_vm.fail(f"grep -qF '{dollar_brace}' {CONFIG}")

    # -----------------------------------------------------------------------
    # (d) idempotency — the template is a seed, not a source of truth
    # -----------------------------------------------------------------------
    with subtest("re-running config-init leaves config.json byte-identical"):
        # Backrest rewrites config.json from the UI, so a re-seeding
        # config-init would silently revert operator changes on every stack
        # restart. `docker start -a` re-runs the exited one-shot with its
        # original env and mounts; `compose run --rm` would collide with the
        # fixed container_name.
        before = services_vm.succeed(f"sha256sum {CONFIG}").split()[0]
        out = services_vm.succeed("docker start -a backrest_config_init 2>&1")
        assert "already exists" in out, (
            f"config-init did not take the leave-it-alone path: {out!r}"
        )
        after = services_vm.succeed(f"sha256sum {CONFIG}").split()[0]
        assert before == after, (
            f"config.json changed across a config-init re-run: {before} -> {after}"
        )

    # -----------------------------------------------------------------------
    # (e) the storage-box-key gate, both directions
    # -----------------------------------------------------------------------
    with subtest("a missing storage-box key keeps backrest down, loudly"):
        # The contract in the compose comments: fail BEFORE Backrest starts,
        # rather than coming up and failing every backup on ssh auth.
        services_vm.succeed(BACKREST + " down")
        services_vm.succeed(f"mv {KEY} {KEY}.hidden")

        services_vm.fail(BACKREST + " up -d --wait --wait-timeout 120")

        # Not running — "created" (dependency never satisfied) or absent both
        # count; inspect failing means it was never even created.
        rc, out = services_vm.execute(
            "docker inspect -f '{{.State.Running}}' backrest"
        )
        assert rc != 0 or out.strip() == "false", (
            f"backrest is up despite the missing key: {out!r}"
        )
        logs = services_vm.succeed("docker logs backrest_config_init 2>&1")
        assert "missing or still the changeme_ placeholder" in logs, (
            f"config-init failed without the loud message: {logs!r}"
        )

    with subtest("a changeme_ placeholder key keeps backrest down too"):
        # The placeholder is the DEFAULT state of a fresh deploy — sops-nix
        # plus the tmpfiles C+ rule always materialise a non-empty file from
        # the committed template — so an empty-only gate would let Backrest
        # start doomed and crash-loop on ssh auth with no alert. This leg
        # keeps the grep in config-init.sh non-vacuous.
        #
        # rm -rf first: the missing-key `up` above made compose manufacture a
        # DIRECTORY at the now-single-file bind source (a narrowed mount fails
        # differently — docker creates missing file sources as dirs), and
        # printf into a directory would fail here for the wrong reason.
        services_vm.succeed(
            f"rm -rf {KEY} && "
            f"printf 'changeme_storagebox_ssh_private_key\\n' > {KEY} && "
            f"chmod 600 {KEY}"
        )
        services_vm.fail(BACKREST + " up -d --wait --wait-timeout 120")
        logs = services_vm.succeed("docker logs backrest_config_init 2>&1")
        assert "sops nixos/secrets.sops.yaml" in logs, (
            f"placeholder key did not produce the sops-flow guidance: {logs!r}"
        )
        services_vm.succeed(f"rm -f {KEY}")

    with subtest("restoring the key unblocks the stack"):
        # rm -rf first: if docker ever started backrest with the key absent it
        # would have manufactured a DIRECTORY at the bind-mount source (the
        # exact failure mode the compose header documents for /config).
        services_vm.succeed(f"rm -rf {KEY} && mv {KEY}.hidden {KEY}")
        # --force-recreate: the failed key-absent `up` above left config_init
        # with a DIRECTORY mountpoint baked into its rootfs (docker manufactures
        # one for a missing single-file bind source); restarting that container
        # onto the now-restored FILE fails "not a directory". A clean redeploy
        # rebuilds it — which is what any real recovery does.
        try:
            services_vm.succeed(
                BACKREST + " up -d --force-recreate --wait --wait-timeout 180"
            )
        except Exception:
            stack_diag("backrest up after key restore")
            raise
        status = services_vm.succeed(
            "docker inspect -f '{{.State.Status}}' backrest"
        ).strip()
        assert status == "running", f"backrest is {status!r} after key restore"

    # -----------------------------------------------------------------------
    # (f) the UI: loopback only
    # -----------------------------------------------------------------------
    with subtest("the UI answers on 127.0.0.1:10002 and nowhere else"):
        try:
            services_vm.wait_until_succeeds(
                "curl -sf --max-time 5 http://127.0.0.1:10002/ -o /dev/null",
                timeout=60,
            )
        except Exception:
            stack_diag("backrest ui")
            raise
        # Positive control first: prove outsider can resolve services-vm and
        # reach it at all (22 is in allowedTCPPorts). Without this, the fail()
        # below would pass identically on a dead vlan or broken hosts entry —
        # curl exit 6/7 either way — and the negative would prove nothing.
        outsider.succeed("nc -z -w 5 services-vm 22")
        # From the VLAN this UI is browse/restore access to every backed-up
        # file; Caddy on the tailnet IP is the only intended way in.
        outsider.fail(
            "curl -sf --max-time 5 http://services-vm:10002/ -o /dev/null"
        )

    # -----------------------------------------------------------------------
    # (g) the shared homelab network
    # -----------------------------------------------------------------------
    with subtest("backrest and ntfy share the homelab network"):
        net = json.loads(services_vm.succeed("docker network inspect homelab"))
        names = sorted(c["Name"] for c in net[0]["Containers"].values())
        assert "backrest" in names and "ntfy" in names, (
            f"expected both on homelab, got {names!r}"
        )

    with subtest("ntfy resolves by name from inside the backrest container"):
        # This is the exact path config.json's webhooks take (http://ntfy/...)
        # — the thing host.docker.internal could never provide on Linux. The
        # image's toolset is not guaranteed, so probe with whatever it has;
        # membership above is the fallback assertion if it has no shell.
        rc, _ = services_vm.execute("docker exec backrest sh -c true")
        if rc != 0:
            print("backrest image has no sh; relying on network membership only")
        else:
            attempts = []
            resolved = False
            for probe in [
                "wget -q -O- http://ntfy/v1/health",
                "getent hosts ntfy",
                "nslookup ntfy",
            ]:
                prc, pout = services_vm.execute(
                    "docker exec backrest sh -c '" + probe + "'"
                )
                attempts.append((probe, prc, pout.strip()))
                if prc == 0:
                    resolved = True
                    break
            assert resolved, (
                f"ntfy did not resolve from inside backrest: {attempts!r}"
            )

    # -----------------------------------------------------------------------
    # (h) a real backup, triggered through the API, lands in the repo
    # -----------------------------------------------------------------------
    with subtest("a triggered backup produces a snapshot in the repo"):
        try:
            resp = trigger_backup(backrest_login())
            assert resp.strip().endswith("HTTP_CODE:200"), (
                f"Backup RPC did not return 200: {resp!r}"
            )
            services_vm.wait_until_succeeds(
                "ls /home/restic/snapshots | grep -q .", timeout=120
            )
            # Hook delivery: a snapshot landing does NOT prove the ntfy hooks
            # fired — backrest logs a hook failure and carries on, so an image
            # bump renaming a hook type would degrade notifications silently
            # while every assertion above stayed green. Grep for the two log
            # shapes that failure takes.
            logs = services_vm.succeed("docker logs backrest 2>&1")
            for bad in ["no handler for hook type", "error running hook"]:
                assert bad not in logs, (
                    f"hook failed to run after the backup ({bad!r} in logs)"
                )
        except Exception:
            stack_diag("triggered backup")
            print(services_vm.execute(
                "curl -si --max-time 10 -X POST "
                "-H 'Content-Type: application/json' "
                "-d '{\"username\":\"admin\",\"password\":\"test_backrest_password\"}' "
                "http://127.0.0.1:10002/v1.Authentication/Login | head -20")[1])
            print(services_vm.execute("ls -laR /home/restic 2>&1 | head -40")[1])
            raise

    # -----------------------------------------------------------------------
    # (i)-(k) the outage matrix — per Idan: auto-init stays, so the harness
    # must pin down exactly what an unreachable storage box costs and when.
    # -----------------------------------------------------------------------
    with subtest("losing the box AFTER startup leaves the UI alive"):
        # backrest 1.9.1 only exits fatally when auto-init fails AT STARTUP;
        # once the orchestrator exists, a dead repo degrades operations but
        # not the process. This asymmetry decides whether an outage costs you
        # the browse/restore UI too — worth pinning as a regression guard for
        # image bumps.
        restarts_before = services_vm.succeed(
            "docker inspect -f '{{.RestartCount}}' backrest").strip()
        services_vm.succeed("systemctl stop sshd")
        time.sleep(15)
        # A backup attempted DURING the outage must error — if it reported
        # success while the repo is unreachable, "degrades operations but not
        # the process" would really mean backups silently writing nowhere.
        resp = trigger_backup(backrest_login())
        assert not resp.strip().endswith("HTTP_CODE:200"), (
            f"Backup RPC claimed success with the box down: {resp!r}"
        )
        # ...and the failed backup cost only that operation: the process is
        # alive (UI answers) and was never restarted.
        services_vm.succeed(
            "curl -sf --max-time 5 http://127.0.0.1:10002/ -o /dev/null")
        restarts_after = services_vm.succeed(
            "docker inspect -f '{{.RestartCount}}' backrest").strip()
        assert restarts_before == restarts_after, (
            f"backrest restarted on a post-startup outage: "
            f"{restarts_before} -> {restarts_after}"
        )
        services_vm.succeed("systemctl start sshd")

    with subtest("a RESTART with the box down keeps the UI up (repo already known)"):
        # First run of this suite expected a crash-loop here and got none —
        # which IS the finding: once a repo has been successfully initialized
        # (backrest records its guid), auto-init no longer gates startup, so a
        # container restart during an outage keeps the UI. The fatal path is
        # exclusive to a repo that has NEVER initialized.
        services_vm.succeed(BACKREST + " down")
        services_vm.succeed("systemctl stop sshd")
        services_vm.succeed(BACKREST + " up -d")
        services_vm.wait_until_succeeds(
            "curl -sf --max-time 5 http://127.0.0.1:10002/ -o /dev/null",
            timeout=120,
        )
        # `down` + `up -d` made a FRESH container, so RestartCount starts at
        # 0 — any crash before the UI answered would show here. Settle 5s
        # first: a crash-then-restart-then-UI sequence increments the counter
        # only after the fact, and an instant read could miss it.
        time.sleep(5)
        restarts = services_vm.succeed(
            "docker inspect -f '{{.RestartCount}}' backrest").strip()
        assert restarts == "0", (
            f"backrest crash-looped on a restart with the box down "
            f"(RestartCount {restarts}); the known-repo path regressed"
        )

    with subtest("box down at FIRST init = crash-loop, UI down"):
        # The deploy-day scenario: brand-new host, storage box unreachable.
        # Wipe every trace of the initialized repo — the sftp target, the
        # operation log, and config.json (whose guid marks the repo as known;
        # config-init reseeds it) — then start. auto-init is fatal here and
        # restart: unless-stopped turns it into a loop. Accepted behaviour
        # (decision 2026-08-30): the loop IS the recovery mechanism, and this
        # subtest documents the cost — no UI until the box first appears.
        services_vm.succeed(BACKREST + " down")
        services_vm.succeed("rm -rf /home/restic/* /mnt/fast/backrest/data/*")
        services_vm.succeed(f"rm -f {CONFIG}")
        services_vm.succeed(BACKREST + " up -d")
        services_vm.wait_until_succeeds(
            "docker inspect -f '{{.RestartCount}}' backrest | grep -vqx 0",
            timeout=120,
        )
        services_vm.fail(
            "curl -sf --max-time 5 http://127.0.0.1:10002/ -o /dev/null")

    with subtest("restoring the box recovers the stack unattended"):
        # Fresh init happens on the next restart-loop iteration; no operator.
        services_vm.succeed("systemctl start sshd")
        services_vm.wait_until_succeeds(
            "curl -sf --max-time 5 http://127.0.0.1:10002/ -o /dev/null",
            timeout=240,
        )
        # And the repo genuinely re-initialized over sftp.
        services_vm.wait_until_succeeds(
            "test -s /home/restic/config", timeout=60)
  '';
}
