# Proton suite — hand-written even though the stack's SHAPE fits
# mk-stack-suite (two long-running containers, no restart:"no" oneshot),
# because the generic harness can only prove ports open and containers
# running, and this stack's whole contract is HOW it behaves with no
# credentials and no route to Proton: banners answered, logins refused
# cleanly, the export loop failing calmly instead of crash-looping. Those
# are protocol dialogues and log/inspect assertions the generic suite
# structurally cannot make.
#
# Genuinely under test:
#   - 🚨 **`serve` holds its listeners with NO auth.json and NO egress.**
#     The deciding factor of the hydroxide-vs-official-bridge choice
#     (compose header), asserted rather than assumed: SMTP answers 220 and
#     a real EHLO dialogue, IMAP answers `* OK` and CAPABILITY, CardDAV
#     challenges with 401 — in a VM with no route anywhere.
#   - 🚨 **A login with no authorised account is a clean IMAP `NO`, and the
#     server survives it.** The per-connection auth path (auth.Manager →
#     missing auth.json → ErrUnauthorized, read at source) is what makes
#     the unbootstrapped bridge safe to run; a hang or crash here would be
#     a crash-loop on every fresh host.
#   - 🚨 **The export sidecar fails CALMLY without credentials**: container
#     still running, RestartCount 0, exactly the compose file's FAILED log
#     line, and NO success stamp — a loop that stamped .last-export-success
#     on a failed sync would be finding #25's shape (green, storing
#     nothing).
#   - 🚨 **The entrypoint override actually took.** The stock entrypoint.py
#     exits 1 without env creds or auth.json; if a future image bump or
#     edit reverts the override, hydroxide crash-loops here immediately.
#   - **The state volume is wired**: `hydroxide status` inside the
#     container reads the mounted (empty) config dir and reports "No
#     logged in user." rather than erroring.
#   - **Ownership**: /mnt/fast/proton/hydroxide is uid 1000 (the image's
#     USER hydroxide; nothing in-container chowns), the archive root is
#     root (the isync image runs as root) — both from the SAME generated
#     stack-dirs.nix the host imports.
#   - **10003/10004/10005 are unreachable from another machine.**
#   - **proton_export has NO healthcheck, deliberately** — pinned like
#     gatus's absence, so nobody "adds the missing healthcheck" that could
#     only watch a sleep loop (compose header carries the reasoning).
#
# Documented gaps — what this suite CANNOT prove, offline by design:
#   - **Login.** No real Proton account ever authenticates here; the
#     bootstrap `auth` flow (TOTP prompt included) is operator-run only.
#   - **Real send.** SMTP AUTH → Proton API → delivery is never exercised;
#     the banner and EHLO dialogue are as far as offline goes.
#   - **Real export.** mbsync never completes a sync; hydroxide's
#     WIP-flagged IMAP against a real mailbox (the accepted risk of the
#     bridge choice) is exactly the part only production exercises. After
#     bootstrap, `docker exec proton_export /sync` + the stamp file is the
#     operator's verification.
#   - **CardDAV data.** 401-challenge liveness only; no contact is ever
#     fetched.
#   - **Staleness alerting.** Nothing here (or in production yet) alerts
#     on an old .last-export-success — stated in the compose file too.

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
    images."ghcr_io_onemorebyte_hydroxide_v0_2_30"
    images."theohbrothers_docker-isync_1_5_0"
  ];

  fixture = ../fixtures/proton.sops.env;

  seedSrv = pkgs.runCommand "srv-seed-proton" { } ''
    mkdir -p $out/stacks/proton
    cp -r ${../../stacks/proton}/. $out/stacks/proton/
    chmod -R u+w $out/stacks/proton
    # A locally-decrypted plaintext .env is gitignored but would still be
    # captured by cp -r into the world-readable store.
    rm -f $out/stacks/proton/.env
    rm -f $out/stacks/proton/.sops.env.example $out/stacks/proton/.sops.env
    cp ${fixture} $out/stacks/proton/.sops.env
  '';

  # /mnt tmpfiles rules from the SAME generated file the real host imports
  # (nixos/stack-dirs.nix), never hand-copied — the wealthfolio/mk-stack-suite
  # pattern. Ownership is the point: hydroxide's image is USER 1000 with no
  # chown, so a root-owned /mnt/fast/proton/hydroxide means `auth` can never
  # write auth.json, and a suite that hardcoded 1000 would assert its own
  # fixture instead of the host's rule.
  stackMntRoots = [
    "/mnt/fast/proton/hydroxide"
    "/mnt/slow/proton-mail-archive"
  ];
  stackDirRules = (import ../../nixos/stack-dirs.nix).systemd.tmpfiles.rules;
  rulePath = r: lib.elemAt (lib.splitString " " r) 1;
  missingRoots = lib.filter (root: !(lib.any (r: rulePath r == root) stackDirRules)) stackMntRoots;
  mntRules =
    if missingRoots == [ ] then
      lib.filter (
        r: lib.any (root: root == rulePath r || lib.hasPrefix (root + "/") (rulePath r)) stackMntRoots
      ) stackDirRules
    else
      throw (
        "proton suite: nixos/stack-dirs.nix has no rule for "
        + lib.concatStringsSep ", " missingRoots
        + " — add the STACK_NOTES/DIR_NOTES entries and re-run nixos/generate-stack-dirs.sh"
      );
in
pkgs.testers.runNixOSTest {
  name = "proton";

  globalTimeout = 2400;

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
            memoryMB = 2048;
            diskMB = 8192;
          })
          (profiles.loadImages {
            inherit pkgs;
            images = stackImages;
            beforeUnits = [ "multi-user.target" ];
          })
        ];

        systemd.services.bootstrap-komodo.wantedBy = lib.mkForce [ ];
        # The new stack-git-sync timer would fail its clone every tick with no Forgejo here.
        systemd.timers.stack-git-sync.wantedBy = lib.mkForce [ ];
        virtualisation.cores = lib.mkForce 2;

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
        ]
        ++ mntRules;

        systemd.services.seed-srv = {
          description = "Seed /srv with the proton stack (test only)";
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
          # The protocol dialogues below are raw-socket; nc is the probe.
          netcat-openbsd
        ];
      };

    # curl EXPLICITLY (the wealthfolio rule): the outsider only ever runs it
    # inside .fail(), and a node without curl makes that negative pass
    # vacuously — failing because the binary is missing, not because the
    # port is closed.
    outsider =
      { pkgs, ... }:
      {
        environment.systemPackages = [ pkgs.curl ];
      };
  };

  testScript = ''
    PROTON = "docker compose -f /srv/stacks/proton/compose.yaml -p proton"
    # Fixture values (tests/fixtures/proton.sops.env) — used for the
    # clean-refusal negative; there is nothing they could ever log in to.
    ACCOUNT = "test_proton_account_not_secret@example.invalid"
    BRIDGE_PASS = "test_bridge_password_not_secret"

    def dump_diag():
        for label, cmd in [
            ("compose ps", f"{PROTON} ps -a"),
            ("hydroxide logs", "docker logs hydroxide 2>&1 | tail -40"),
            ("export logs", "docker logs proton_export 2>&1 | tail -40"),
            ("decrypt journal",
             "journalctl -u decrypt-sops-envs --no-pager -o cat | tail -20"),
            ("state dir", "ls -la /mnt/fast/proton/hydroxide"),
            ("archive dir", "ls -la /mnt/slow/proton-mail-archive"),
        ]:
            print(f"--- {label} ---")
            print(services_vm.execute(cmd)[1])

    start_all()

    services_vm.wait_for_unit("multi-user.target")
    services_vm.wait_for_unit("docker-network-homelab.service")
    services_vm.wait_for_unit("load-test-images.service")

    try:
        with subtest("the fixture .sops.env decrypted to a 0600 .env"):
            # The artifact, not the unit: decrypt-sops-envs is a transient
            # oneshot on a minutely timer (mk-stack-suite's rule).
            services_vm.wait_until_succeeds(
                "test -s /srv/stacks/proton/.env", timeout=90
            )
            mode = services_vm.succeed(
                "stat -c %a /srv/stacks/proton/.env"
            ).strip()
            assert mode == "600", f".env is mode {mode}, expected 600"

        with subtest("🚨 the stack comes up with NO creds and NO egress"):
            # --wait is safe: hydroxide has a healthcheck, proton_export has
            # none and --wait then only waits for `running` (the logging-
            # stack precedent; only NAMING a healthcheck-less service in a
            # health condition errors, finding #42). No route to the
            # internet exists in this VM, so passing at all proves boot
            # needs neither Proton nor a registry.
            services_vm.succeed(f"{PROTON} up -d --wait --wait-timeout 300")

        with subtest("🚨 SMTP answers a real banner and EHLO dialogue on 10003"):
            # The strongest offline signal: `serve` accepted, the go-smtp
            # goroutine greeted (220), and command dispatch works (250 with
            # capabilities). Proves nothing about login or Proton — stated
            # in the header.
            services_vm.wait_until_succeeds(
                "nc -w 5 127.0.0.1 10003 </dev/null | head -1 | grep -q '^220 '",
                timeout=60,
            )
            services_vm.succeed(
                "printf 'EHLO probe\\r\\nQUIT\\r\\n' | nc -w 5 127.0.0.1 10003 "
                "| grep -q '^250'"
            )

        with subtest("IMAP greets and answers CAPABILITY on 10004"):
            services_vm.succeed(
                "nc -w 5 127.0.0.1 10004 </dev/null | head -1 "
                "| grep -q '^\\* OK'"
            )
            services_vm.succeed(
                "printf 'a1 CAPABILITY\\r\\na2 LOGOUT\\r\\n' "
                "| nc -w 5 127.0.0.1 10004 | grep -q '^\\* CAPABILITY'"
            )

        with subtest("🚨 an unauthorised IMAP login is a clean NO, and serve survives"):
            # The per-connection auth path: no auth.json in the volume, so
            # LOGIN must be refused (never hang, never crash the server).
            # This is the exact state of every fresh host before the
            # operator bootstrap.
            out = services_vm.succeed(
                "printf 'a1 LOGIN \"%s\" \"%s\"\\r\\na2 LOGOUT\\r\\n' "
                f"'{ACCOUNT}' '{BRIDGE_PASS}' "
                "| nc -w 10 127.0.0.1 10004"
            )
            assert "a1 NO" in out, f"expected 'a1 NO', got:\n{out}"
            # Still alive after the refusal:
            services_vm.succeed(
                "nc -w 5 127.0.0.1 10004 </dev/null | head -1 "
                "| grep -q '^\\* OK'"
            )

        with subtest("CardDAV challenges with 401 on 10005"):
            # Anonymous request → WWW-Authenticate: Basic + 401 (main.go's
            # handler). Liveness only: no contact is ever fetched offline.
            code = services_vm.succeed(
                "curl -s -o /dev/null -w '%{http_code}' --max-time 10 "
                "http://127.0.0.1:10005/"
            ).strip()
            assert code == "401", f"CardDAV gave {code}, expected 401"

        with subtest("the state volume is wired: status reads the mounted dir"):
            # ListUsernames on a missing auth.json is (nil, nil) — read at
            # source — so status must report cleanly, not error. Also
            # proves docker exec lands in the image's USER with the right
            # HOME, which is what the operator bootstrap depends on.
            services_vm.succeed(
                "docker exec hydroxide /app/hydroxide status "
                "| grep -q 'No logged in user'"
            )

        with subtest("ownership: state dir is uid 1000, archive root is root"):
            # From nixos/stack-dirs.nix via mntRules — the host's rules, not
            # this suite's opinion. hydroxide (USER 1000, no chown) cannot
            # write auth.json into a root-owned dir; the isync image runs as
            # root and owns the archive.
            uid = services_vm.succeed(
                "stat -c %u /mnt/fast/proton/hydroxide"
            ).strip()
            assert uid == "1000", f"state dir owned by uid {uid}, expected 1000"
            uid = services_vm.succeed(
                "stat -c %u /mnt/slow/proton-mail-archive"
            ).strip()
            assert uid == "0", f"archive root owned by uid {uid}, expected 0"

        with subtest("🚨 the export loop fails CALMLY without credentials"):
            # The compose file's exact failure line, from a first sync that
            # connected to hydroxide and was refused. The loop must then
            # SLEEP, not exit: running, RestartCount 0, no hot retry.
            services_vm.wait_until_succeeds(
                "docker logs proton_export 2>&1 "
                "| grep -q 'sync FAILED - no login yet'",
                timeout=120,
            )
            state = services_vm.succeed(
                "docker inspect -f '{{.State.Status}} {{.RestartCount}}' "
                "proton_export"
            ).strip()
            assert state == "running 0", (
                f"proton_export is '{state}', expected 'running 0' — the "
                "no-creds path is crash-looping instead of sleeping"
            )
            # Exactly one attempt in this window (the next is 24h away):
            n = services_vm.succeed(
                "docker logs proton_export 2>&1 | grep -c 'sync FAILED' || true"
            ).strip()
            assert n == "1", f"{n} failed-sync lines in one boot — hot loop?"

        with subtest("a failed sync leaves NO success stamp"):
            # A loop that stamped .last-export-success on failure would be
            # finding #25's shape: a backup signal that is green while
            # storing nothing.
            services_vm.fail("test -e /mnt/slow/proton-mail-archive/.last-export-success")

        with subtest("proton_export has NO healthcheck, and that is deliberate"):
            # Pinned like gatus's absence: any probe here could only watch
            # the sleep loop, and a stamp-age probe would page unhealthy for
            # the entire pre-bootstrap era. The compose comment carries the
            # reasoning; this stops someone "fixing" it.
            out = services_vm.succeed(
                "docker inspect --format '{{json .Config.Healthcheck}}' "
                "proton_export"
            ).strip()
            assert out in ("null", "{}"), f"proton_export grew a healthcheck: {out}"

        with subtest("🚨 10003-10005 are unreachable from another machine"):
            ip = services_vm.succeed(
                "ip -4 -o addr show eth1 | awk '{print $4}' | cut -d/ -f1"
            ).strip()
            outsider.wait_for_unit("network.target")
            for port in (10003, 10004, 10005):
                # curl telnet:// exits nonzero on a refused/filtered TCP
                # connect, which is all the negative needs.
                outsider.fail(
                    f"curl -s --max-time 10 telnet://{ip}:{port} </dev/null"
                )
            # Positive control: the outsider can reach the VM at all.
            outsider.succeed(f"ping -c1 -W5 {ip} >/dev/null")

        with subtest("hydroxide is still healthy after the negatives"):
            services_vm.succeed(
                "test \"$(docker inspect -f '{{.State.Health.Status}}' "
                "hydroxide)\" = healthy"
            )
    except Exception:
        dump_diag()
        raise
  '';
}
