# Services VM: the sops-decrypt -> docker-network -> Arcane boot chain, plus
# the stacks themselves behind Caddy.
#
# Genuinely under test:
#   - decrypt-sops-envs.service turning .sops.env into .env, with modes, and
#     its ordering against srv.mount
#   - docker-network-homelab ordering before bootstrap-arcane (containers on
#     the shared network cannot resolve each other otherwise)
#   - bootstrap-arcane bringing Arcane up on 127.0.0.1:10000
#   - the real compose files for every light stack, with real healthchecks
#   - Caddy's routing table and its 404 fallback
#   - notify-failure@.service actually delivering to Ntfy — the failure signal
#     everything else depends on
#   - the firewall dropping VLAN traffic to every service port, verified from
#     another host. NOT under test here: loopback-only *publishing* — the
#     interface that would expose a 0.0.0.0 bind is the trusted tailscale0,
#     which needs a real tailnet peer; those probes live in tailnet.nix.
#
# hardware-configuration.nix is not imported: it mounts real partitions by
# partlabel. Its tmpfiles rules are reproduced below; only the /srv/stacks
# ownership rule is cross-checked (the tmpfiles-ownership lint) — the
# remaining rules are hand-copied and CAN drift without anything noticing.

{
  pkgs,
  lib,
  images,
  profiles,
  sopsModule,
  ...
}:

let
  # Seeded into /srv/stacks so decrypt-sops-envs.service processes them.
  # backrest is seeded but not started: its image is multi-GB and lives in the
  # heavy suite, but its fixture carries the bcrypt value with '$' in it, which
  # is what makes the quoting assertion below real rather than decorative.
  seededStacks = [
    "ntfy"
    "util"
    "caddy"
    "backrest"
  ];

  startedStacks = [
    "ntfy"
    "util"
    "caddy"
  ];

  stackImages = [
    # For the backup-prepare subtest's stand-in database container.
    images."postgres_17_9-alpine"
    images."ghcr_io_getarcaneapp_arcane_v1_17_4"
    images."binwiederhier_ntfy_v2_11_0"
    images."ghcr_io_alam00000_bentopdf_1_16_1"
    images."ghcr_io_civilblur_mazanoke_v1_1_5"
    images."ghcr_io_idanreed_caddy-cloudflare_2_11_2"
  ];

  # The production Caddyfile asks for DNS-01 against Cloudflare, which needs a
  # real API token and a real zone. Swap only that block for Caddy's internal
  # CA and assert the swap matched exactly once — so any other edit to the file
  # is still tested verbatim, and a restructure that silently stops matching
  # fails the build rather than testing a stale copy.
  testCaddyfile =
    pkgs.runCommand "Caddyfile.test" { nativeBuildInputs = [ pkgs.python3 ]; }
      ''
        python3 - <<'PY'
        import os, re, sys
        src = open("${../../stacks/caddy/Caddyfile}").read()
        pattern = re.compile(r"\n\ttls \{\n\t\tdns cloudflare \{env\.CLOUDFLARE_API_TOKEN\}\n\t\}\n")
        out, n = pattern.subn("\n\ttls internal\n", src)
        if n != 1:
            print(f"expected exactly one DNS-01 tls block in the Caddyfile, found {n}.",
                  file=sys.stderr)
            print("The suite's substitution is stale — update tests/suites/services-vm.nix.",
                  file=sys.stderr)
            sys.exit(1)
        open(os.environ["out"], "w").write(out)
        PY
      '';

  # Seeds /srv the way the real host gets it: Arcane's git sync on the live
  # machine, a store copy here. Fixture .sops.env files stand in for the real
  # encrypted ones, so decrypt-sops-envs.service is exercised for real.
  seedSrv = pkgs.runCommand "srv-seed" { } ''
    mkdir -p $out/arcane $out/stacks
    cp ${../../arcane/compose.yaml} $out/arcane/compose.yaml
    cp ${../fixtures/arcane.sops.env} $out/arcane/.sops.env

    ${lib.concatMapStringsSep "\n" (s: ''
      mkdir -p $out/stacks/${s}
      cp -r ${../../stacks + "/${s}"}/. $out/stacks/${s}/
      chmod -R u+w $out/stacks/${s}
      rm -f $out/stacks/${s}/.sops.env.example
      ${lib.optionalString (builtins.pathExists (../fixtures + "/${s}.sops.env")) ''
        cp ${../fixtures + "/${s}.sops.env"} $out/stacks/${s}/.sops.env
      ''}
    '') seededStacks}

    # Caddy's routing is what is under test, not its ACME provider.
    cp ${testCaddyfile} $out/stacks/caddy/Caddyfile
  '';
in
pkgs.testers.runNixOSTest {
  name = "services-vm";

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
          profiles.testSshAccess
          (profiles.sopsFixture ../fixtures/services-vm.sops.yaml)
          (profiles.sized {
            memoryMB = 4096;
            diskMB = 12288;
          })
          (profiles.loadImages {
            inherit pkgs;
            images = stackImages;
            beforeUnits = [ "bootstrap-arcane.service" ];
          })
        ];

        # decrypt-sops-envs.service and bootstrap-arcane.service both
        # `requires = srv.mount`. Without a real mount unit at /srv they would
        # fail to start, and the ordering this suite exists to check would
        # never be exercised. tmpfs gives a genuine .mount unit.
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
          "d /srv/arcane 0755 root root -"
          "d /srv/stacks 0755 1000 1000 -"
          "d /var/lib/sops-nix 0700 root root -"
          # Volume roots the stacks bind-mount into.
          "d /mnt/fast/caddy 0755 root root -"
          "d /mnt/fast/ntfy 0755 root root -"
          "d /mnt/fast/_dumps 0755 root root -"
          # No key planting here any more: both backup SSH keys are
          # sops-managed now (BACKUP_VPS_SSH_KEY / BACKUP_STORAGEBOX_SSH_KEY
          # in the fixture, carrying the committed test keys), so the suite
          # exercises the production delivery path — sops-nix symlink for the
          # VPS key, the tmpfiles C+ copy for the storagebox key. A test C+
          # rule would overwrite that chain and mask its breakage.
        ];

        # Populate /srv before anything reads it.
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
          docker-compose
          jq
          # The test script inspects dumps; backup-prepare.service brings its
          # own sqlite via its unit path.
          sqlite
        ];
      };

    # Another host on the LAN. The services VM trusts tailscale0 wholesale, so
    # anything this node can reach on a non-tailnet interface is reachable from
    # the whole VLAN. It also drives the SSH assertions.
    outsider = {
      environment.etc."test-ssh-key" = {
        source = ../keys/test-ssh-key;
        mode = "0600";
      };
    };
  };

  testScript = ''
    import json

    start_all()
    # decrypt-sops-envs is a transient oneshot now (the timer must be able to
    # re-fire it); bootstrap-arcane Requires+After it, so arcane being up IS
    # the proof the decrypt pass succeeded.
    services_vm.wait_for_unit("bootstrap-arcane.service")

    # -----------------------------------------------------------------------
    # Secret decryption
    # -----------------------------------------------------------------------
    with subtest("decrypt-sops-envs turns every .sops.env into a 0600 .env"):
        # util is deliberately absent: it has no secrets, so no .sops.env and
        # therefore no .env. Its compose file declares no env_file either — the
        # env-file-coverage lint is what keeps those two facts consistent.
        for path in ["/srv/arcane/.env",
                     "/srv/stacks/ntfy/.env",
                     "/srv/stacks/caddy/.env"]:
            services_vm.succeed(f"test -s {path}")
            mode = services_vm.succeed(f"stat -c '%a' {path}").strip()
            assert mode == "600", f"{path} is mode {mode}, expected 600"

        services_vm.fail("test -e /srv/stacks/util/.env")

    with subtest("the sops-managed backup SSH keys land where consumers look"):
        # BACKUP_VPS_SSH_KEY: custom sops path -> a symlink into
        # /run/secrets.d, fine for the host-side ssh in backup-prepare.
        # BACKUP_STORAGEBOX_SSH_KEY: a REAL file via the tmpfiles C+ copy,
        # because backrest's config-init bind-mounts /var/lib/backup into a
        # container where a /run/secrets.d symlink dangles. Byte-identity
        # matters: a key corrupted in the sops round-trip fails ssh late and
        # silently, so cmp against the committed originals, not just -s.
        services_vm.succeed("test -L /var/lib/backup/vps_ed25519")
        services_vm.succeed(
            "cmp /var/lib/backup/vps_ed25519 ${../keys/test-ssh-key}")
        services_vm.succeed(
            "test -f /var/lib/backup/storagebox_ed25519 "
            "&& test ! -L /var/lib/backup/storagebox_ed25519")
        services_vm.succeed(
            "cmp /var/lib/backup/storagebox_ed25519 ${../keys/test-storagebox-key}")
        for path in ["/var/lib/backup/vps_ed25519",
                     "/var/lib/backup/storagebox_ed25519"]:
            mode = services_vm.succeed(f"stat -L -c '%a %U' {path}").strip()
            assert mode == "600 root", f"{path} is {mode}, expected 600 root"

    with subtest("values containing '$' survive decryption intact"):
        # CLAUDE.md warns that these must be single-quoted or the
        # decrypt-and-source path expands them. Verified against a bcrypt-shaped
        # fixture value rather than left as folklore.
        # The '$'-carrier moved to RESTIC_PASSWORD when the bcrypt became
        # base64 (finding 6: backrest decodes passwordBcrypt, so the hash is
        # stored encoded and no longer contains '$').
        line = services_vm.succeed(
            "grep '^RESTIC_PASSWORD=' /srv/stacks/backrest/.env"
        ).strip()
        assert "te$t_re$tic_pa$$word" in line, (
            f"the '$'-bearing value did not survive decryption: {line!r}"
        )

    # -----------------------------------------------------------------------
    # Boot ordering
    # -----------------------------------------------------------------------
    with subtest("the shared docker network exists before Arcane starts"):
        # Containers cannot reach a loopback-bound host port, so the homelab
        # network is how Backrest reaches Ntfy. If bootstrap-arcane wins the
        # race, stacks attach to a network that does not exist yet.
        services_vm.wait_for_unit("docker-network-homelab.service")
        services_vm.succeed("docker network inspect homelab >/dev/null")

        # The timestamp comparison below is timing luck on its own:
        # bootstrap-arcane sleeps 5s and loads images while the network unit
        # finishes in well under a second, so deleting the before= edge would
        # almost never flip the order. The dependency edge itself is the
        # contract — assert it directly, and keep the timestamps only as
        # corroboration that it was honoured on this boot.
        after_deps = services_vm.succeed(
            "systemctl show -p After --value bootstrap-arcane.service"
        )
        assert "docker-network-homelab.service" in after_deps, (
            f"bootstrap-arcane has no ordering edge on docker-network-homelab: "
            f"{after_deps!r}"
        )

        # Both units must have ENTERED active before their timestamps mean
        # anything — monotonic 0 is "never started", and comparing against it
        # reports a phantom ordering violation while bootstrap-arcane is still
        # in its start sleep.
        services_vm.wait_for_unit("bootstrap-arcane.service")

        net_t = services_vm.succeed(
            "systemctl show -p ActiveEnterTimestampMonotonic --value "
            "docker-network-homelab.service"
        ).strip()
        arc_t = services_vm.succeed(
            "systemctl show -p ActiveEnterTimestampMonotonic --value "
            "bootstrap-arcane.service"
        ).strip()
        assert int(net_t) > 0 and int(arc_t) > 0, \
            f"a unit never activated (net={net_t}, arcane={arc_t})"
        assert int(net_t) <= int(arc_t), (
            f"docker-network-homelab activated at {net_t} but bootstrap-arcane "
            f"at {arc_t} — the ordering is not being honoured"
        )

    with subtest("Arcane answers on loopback and the LAN cannot reach it"):
        services_vm.wait_for_unit("bootstrap-arcane.service")
        services_vm.wait_until_succeeds(
            "curl -sf --max-time 5 http://127.0.0.1:10000/ -o /dev/null", timeout=120
        )
        # Arcane mounts the docker socket, so reachability from off-host would
        # be a root-equivalent interface behind only its own login. What this
        # negative proves is FIREWALL posture: the outsider sits on the plain
        # VLAN, which the firewall drops wholesale. It says nothing about the
        # loopback publish address, because the interface that could expose a
        # 0.0.0.0 bind is the *trusted* tailscale0 — unreachable from this
        # suite. The on-tailnet probes live in tailnet.nix.
        outsider.fail("curl -sf --max-time 5 http://services-vm:10000/ -o /dev/null")

    # -----------------------------------------------------------------------
    # Stacks
    # -----------------------------------------------------------------------
    # On the real host Arcane brings these up from /srv/stacks. Driving compose
    # directly tests the compose files, the decrypted env and the network,
    # without depending on Arcane's scheduler.
    with subtest("every light stack starts and reports healthy"):
        for stack in ${builtins.toJSON startedStacks}:
            services_vm.succeed(
                f"docker compose -f /srv/stacks/{stack}/compose.yaml "
                f"-p {stack} up -d --wait --wait-timeout 180"
            )

    with subtest("ntfy is healthy and the LAN cannot reach it"):
        services_vm.wait_until_succeeds(
            "curl -sf --max-time 5 http://127.0.0.1:10001/v1/health "
            "| jq -e '.healthy == true'", timeout=120
        )
        # Firewall posture only, as with Arcane above — the loopback-binding
        # question is answered from a real tailnet peer in tailnet.nix.
        outsider.fail("curl -sf --max-time 5 http://services-vm:10001/v1/health")

    with subtest("util services answer"):
        services_vm.wait_until_succeeds(
            "curl -sf --max-time 5 http://127.0.0.1:10401/ -o /dev/null", timeout=120)
        services_vm.wait_until_succeeds(
            "curl -sf --max-time 5 http://127.0.0.1:10403/ -o /dev/null", timeout=120)
        # Same caveat: this proves the firewall drops VLAN traffic, not that
        # the port is published on loopback alone.
        outsider.fail("curl -sf --max-time 5 http://services-vm:10401/ -o /dev/null")

    # -----------------------------------------------------------------------
    # Caddy routing
    # -----------------------------------------------------------------------
    with subtest("Caddy routes by Host and 404s unknown subdomains"):
        services_vm.wait_for_open_port(443)

        # -k because the cert comes from Caddy's internal CA here; the routing
        # decision is what is being checked.
        body = services_vm.succeed(
            "curl -sk --max-time 10 --resolve arcane.svc.idanreed.com:443:127.0.0.1 "
            "https://arcane.svc.idanreed.com/ -o /dev/null -w '%{http_code}'"
        ).strip()
        assert body.startswith("2") or body.startswith("3"), \
            f"arcane route returned {body}"

        # The explicit fallback. Without it a stray subdomain gets a blank 200
        # from the wildcard site, which looks like a working service.
        out = services_vm.succeed(
            "curl -sk --max-time 10 --resolve nope.svc.idanreed.com:443:127.0.0.1 "
            "https://nope.svc.idanreed.com/ -w '\\n%{http_code}'"
        )
        assert "No such service" in out and out.strip().endswith("404"), \
            f"unknown subdomain returned: {out!r}"

    # -----------------------------------------------------------------------
    # The failure signal
    # -----------------------------------------------------------------------
    with subtest("a failing unit delivers a notification to Ntfy"):
        # backup-staleness-check fails by design when no backup has ever run,
        # and carries OnFailure=notify-failure@. If this path is broken, every
        # other failure on this host is silent — which is the whole reason the
        # unit exists.
        services_vm.fail("systemctl start backup-staleness-check.service")

        # Poll ntfy for the CONTENT rather than gating on the notifier unit:
        # `systemctl show -p Result` reports "success" for a unit that has not
        # finished (or even started) yet, so it cannot synchronise anything —
        # it let the first version of this subtest race the delivery and lose.
        # since=all matters too: without it the poll endpoint only returns
        # messages that arrive after the request.
        try:
            services_vm.wait_until_succeeds(
                "curl -sf --max-time 10 "
                "'http://127.0.0.1:10001/alerts/json?poll=1&since=all' "
                "| grep -q backup-staleness-check",
                timeout=60,
            )
        except Exception:
            # The notifier unit never fails by design (a notifier that can
            # fail just produces more failed units), so its journal is the
            # only place a delivery error shows up.
            print(services_vm.execute(
                "journalctl -u 'notify-failure@backup-staleness-check.service' "
                "--no-pager | tail -20")[1])
            raise

        msgs = services_vm.succeed(
            "curl -sf --max-time 10 "
            "'http://127.0.0.1:10001/alerts/json?poll=1&since=all'"
        )
        alerts = [m for m in map(json.loads, filter(str.strip, msgs.splitlines()))
                  if m.get("event") == "message"
                  and "backup-staleness-check" in m.get("title", "")]
        assert alerts, f"grep saw the alert but the parse did not: {msgs!r}"
        # The body carries the systemctl status snippet — the part a human
        # actually acts on from their phone.
        assert "backup-staleness-check" in alerts[0].get("message", ""), \
            f"alert has no useful body: {alerts[0]!r}"

        # This failure was deliberate; clear it so the suite-final
        # no-failed-units sweep only catches failures nobody asked for.
        services_vm.succeed("systemctl reset-failed backup-staleness-check.service")

    # -----------------------------------------------------------------------
    # backup-prepare: local dumps + the loud-failure contract
    # -----------------------------------------------------------------------
    # The script's local mechanisms, against live targets: a real postgres
    # gets pg_dumpall'd through docker exec, a real sqlite file gets a
    # WAL-safe .backup. The VPS half is deliberately broken to pin the
    # honest-failure contract — in BOTH unusable key states, since the
    # fixture now delivers a working key: (1) the key still holding the
    # committed template's changeme_ placeholder (what a fresh deploy
    # installs verbatim), (2) the key missing outright. Each: local dumps
    # still land, the unit still FAILS, the warning names the state, no
    # .last-success is stamped — and the failure reaches ntfy like every
    # other. The green path incl. the VPS pull lives in the tailnet suite,
    # which has a real VPS to pull from.
    with subtest("backup-prepare dumps live databases and fails loudly on an unusable VPS key"):
        # Stand-in for a stack database, named per the script's convention.
        services_vm.succeed(
            "docker run -d --name paperless_db "
            "-e POSTGRES_USER=paperless -e POSTGRES_PASSWORD=paperless "
            "-e POSTGRES_DB=paperless postgres:17.9-alpine"
        )
        # -h 127.0.0.1 on purpose: the postgres entrypoint's first-init runs a
        # TEMPORARY server that answers pg_isready on the unix socket, then
        # stops before the real server starts — a socket check can pass inside
        # that window and the pg_dumpall below then hits a dead server (bit
        # sweep 13 under load). The temp server never listens on TCP.
        services_vm.wait_until_succeeds(
            "docker exec paperless_db pg_isready -h 127.0.0.1 -U paperless",
            timeout=60
        )
        # And a live sqlite in one of the script's known locations.
        services_vm.succeed(
            "mkdir -p /mnt/fast/vaultwarden && "
            "sqlite3 /mnt/fast/vaultwarden/db.sqlite3 "
            "\"create table t(x); insert into t values (42);\""
        )

        # State (1): a changeme_ placeholder. Move the delivered key (a sops
        # symlink) aside and plant what a deploy with the untouched committed
        # template would install.
        KEY = "/var/lib/backup/vps_ed25519"
        services_vm.succeed(f"mv {KEY} {KEY}.delivered")
        services_vm.succeed(
            f"printf 'changeme_backup_vps_ssh_private_key\\n' > {KEY} "
            f"&& chmod 600 {KEY}")
        services_vm.fail("systemctl start backup-prepare.service")
        out = services_vm.succeed(
            "journalctl -u backup-prepare --no-pager | tail -20")
        assert "still a changeme_ placeholder" in out, \
            f"no loud placeholder warning: {out!r}"

        # State (2): the key missing outright.
        services_vm.succeed(f"rm {KEY}")
        services_vm.succeed("systemctl reset-failed backup-prepare.service")
        services_vm.fail("systemctl start backup-prepare.service")
        out = services_vm.succeed(
            "journalctl -u backup-prepare --no-pager | tail -20")
        assert "vps_ed25519 missing" in out, f"no loud warning: {out!r}"

        # The failure did NOT take the local dumps down with it.
        services_vm.succeed("test -s /mnt/fast/_dumps/paperless.sql")
        services_vm.succeed(
            "grep -q 'CREATE ROLE paperless' /mnt/fast/_dumps/paperless.sql")
        services_vm.succeed("test -s /mnt/fast/_dumps/vaultwarden.sqlite")
        services_vm.succeed(
            "sqlite3 /mnt/fast/_dumps/vaultwarden.sqlite 'select x from t' "
            "| grep -qx 42")

        # No success stamp on a partial run — the staleness canary must stay
        # red rather than certifying a backup that skipped the VPS.
        services_vm.fail("test -e /mnt/fast/_dumps/.last-success")

        # And the failure is not silent.
        services_vm.wait_until_succeeds(
            "curl -sf --max-time 10 "
            "'http://127.0.0.1:10001/alerts/json?poll=1&since=all' "
            "| grep -q backup-prepare",
            timeout=60,
        )
        services_vm.succeed("docker rm -f paperless_db")

        # Restore the sops-delivered key: later subtests (and the reboot)
        # must see the production state, not this subtest's sabotage.
        services_vm.succeed(f"mv {KEY}.delivered {KEY}")

        # Deliberate failures (the unusable VPS key IS the subject) — clear
        # them so the suite-final no-failed-units sweep stays meaningful.
        services_vm.succeed("systemctl reset-failed backup-prepare.service")

    # -----------------------------------------------------------------------
    # A stack delivered AFTER boot gets its secrets without a reboot
    # -----------------------------------------------------------------------
    # The gap that used to be a known issue: Arcane's git sync delivers
    # .sops.env at runtime, the old boot-only oneshot never decrypted it, and
    # compose started with unset variables. A minutely timer re-runs the
    # (make-style, idempotent) decrypt now — this subtest plays the part of
    # the git sync and waits out one tick.
    with subtest("a runtime-synced stack gets its .env within a timer tick"):
        services_vm.succeed("systemctl is-active decrypt-sops-envs.timer")
        services_vm.succeed(
            "mkdir -p /srv/stacks/latestack && "
            "cp /srv/stacks/ntfy/.sops.env /srv/stacks/latestack/.sops.env"
        )
        # 150s, not one 60s tick: OnCalendar=minutely plus systemd's default
        # AccuracySec=1min means a tick can land up to ~120s after the copy in
        # the worst case; the slack on top keeps a slow VM from flaking.
        services_vm.wait_until_succeeds(
            "test -s /srv/stacks/latestack/.env", timeout=150
        )
        mode = services_vm.succeed("stat -c '%a' /srv/stacks/latestack/.env").strip()
        assert mode == "600", f"late .env is mode {mode}"
        # The decrypt runs as root, so without the explicit chown the .env
        # would land root-owned at 0600 — unreadable to Arcane (PUID 1000),
        # which is what deploys the stack. The mode check above cannot catch
        # that; the owner check is what pins it.
        owner = services_vm.succeed(
            "stat -c '%u:%g' /srv/stacks/latestack/.env").strip()
        assert owner == "1000:1000", \
            f"late .env is owned {owner}, expected 1000:1000 (Arcane's PUID)"

        # And no mtime churn for everyone else: a tick that changes nothing
        # must rewrite nothing (compose watches these files).
        before = services_vm.succeed("stat -c '%Y' /srv/stacks/ntfy/.env").strip()
        services_vm.succeed("systemctl start decrypt-sops-envs.service")
        after = services_vm.succeed("stat -c '%Y' /srv/stacks/ntfy/.env").strip()
        assert before == after, "an unchanged .env was rewritten by a re-run"

    # -----------------------------------------------------------------------
    # SSH auth surface
    # -----------------------------------------------------------------------
    # 22 is the only port this host opens to the VLAN, so what sshd accepts IS
    # the exposure. Key is the committed test keypair from
    # profiles.testSshAccess.
    with subtest("key login works, passwords and root are refused"):
        SSH = ("ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
               "-o ConnectTimeout=10 -o BatchMode=yes")
        outsider.succeed(f"{SSH} -i /etc/test-ssh-key idan@services-vm true")
        outsider.succeed(f"{SSH} -i /etc/test-ssh-key idan@services-vm sudo -n true")
        methods = outsider.succeed(
            f"{SSH} -v -o PubkeyAuthentication=no idan@services-vm true 2>&1 "
            "| grep 'Authentications that can continue' | head -1 || true"
        )
        assert "publickey" in methods, f"never saw the auth offer: {methods!r}"
        assert "password" not in methods, f"sshd offers passwords: {methods!r}"
        outsider.fail(f"{SSH} -i /etc/test-ssh-key root@services-vm true")

    # -----------------------------------------------------------------------
    # Reboot
    # -----------------------------------------------------------------------
    with subtest("the boot chain reconverges after a reboot"):
        services_vm.shutdown()
        services_vm.start()
        services_vm.wait_for_unit("docker-network-homelab.service")
        services_vm.wait_for_unit("bootstrap-arcane.service")
        services_vm.wait_until_succeeds(
            "curl -sf --max-time 5 http://127.0.0.1:10000/ -o /dev/null", timeout=180
        )

    # -----------------------------------------------------------------------
    # Timers
    # -----------------------------------------------------------------------
    with subtest("every production timer is armed after the reboot"):
        # The units were exercised above by starting them directly, which
        # proves nothing about the timers: a timer missing its wantedBy, or
        # one whose Unit= points at a renamed service, is active-looking but
        # never fires — and a backup timer that never fires is exactly the
        # silent failure backup-staleness-check exists to catch. Checked
        # post-reboot because that is when wantedBy wiring shows its truth.
        for timer in ["backup-prepare.timer",
                      "backup-staleness-check.timer",
                      "decrypt-sops-envs.timer"]:
            services_vm.succeed(f"systemctl is-active {timer}")
            # list-timers prints '-' in NEXT for an armed-but-never-elapsing
            # timer, so demand a real next elapse, not just active state.
            line = services_vm.succeed(
                f"systemctl list-timers --all --no-legend {timer}").strip()
            assert line and not line.startswith("-"), \
                f"{timer} is active but has no next elapse: {line!r}"

    # -----------------------------------------------------------------------
    # Nothing failed that the suite did not fail on purpose
    # -----------------------------------------------------------------------
    with subtest("no unit is left failed at suite end"):
        # The deliberate failures above (backup-staleness-check,
        # backup-prepare) were reset-failed in their own subtests, so
        # anything remaining here is a real regression the rest of the suite
        # did not look at.
        failed = services_vm.succeed("systemctl --failed --no-legend").strip()
        assert failed == "", f"failed units at suite end:\n{failed}"
  '';
}
