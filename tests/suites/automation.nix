# Automation suite (heavy): the home-automation stack on the services VM —
# Home Assistant, Mosquitto and Frigate, plus three oneshots (mosquitto-init,
# ha-config-init, automation-init). Hand-written for two reasons, and the
# second one matters more than the usual "oneshots break the generic suite":
#
#   1. mk-stack-suite asserts every container is `running`, which a completed
#      restart:"no" oneshot is not.
#   2. **Frigate reports HEALTHY on a broken config.** An invalid config does
#      not crash it — it starts in SAFE MODE with `cameras: {}` and MQTT off,
#      and its builtin healthcheck goes green. A generic "is it up" suite
#      would pass on a stack that is doing nothing at all. Subtest 7 is the
#      only thing standing between that and a green run.
#
# Annex §6 of ServerNotes/designs/service-automation-stack-research.md is the
# assertion spec.
#
# Genuinely under test:
#   - decrypt-sops-envs -> a 0600 .env owned 1000:1000, and env threading END
#     TO END: the MQTT credentials and the HA owner exist only in the
#     encrypted fixture, so a working broker login and a working HA login
#     prove the whole sops -> .env -> env_file chain
#   - **the five-minute auto-revert is not armed.** Since 2026.8.0 HA migrates
#     `http:` into a storage-backed config, stages it as *pending*, and
#     reverts it after five minutes unless a human promotes it in the UI. The
#     suite asserts HA logged `Using stable HTTP config` and NOT
#     `Using pending HTTP config` — the whole contract is that one line — and
#     then drives a real proxied request, because the store is not validated
#     on load and a malformed pre-seed fails silently rather than loudly
#   - a proxied request actually working: X-Forwarded-For from the bridge
#     gateway gets a normal response instead of the 400 HA returns when it
#     sees that header without trusted_proxies configured
#   - the MQTT round trip with authentication on, in both directions, plus
#     the negatives (anonymous refused, wrong password refused) — this is the
#     Frigate -> broker -> Home Assistant event chain the stack exists for
#   - the password file being hashed sha512-pbkdf2 rather than argon2id, which
#     is what keeps it readable by the pinned 2.0.x broker
#   - Frigate NOT in safe mode, its MQTT client connected, and its
#     unauthenticated forced-admin port 5000 not published
#   - loopback-only publishing asserted from another host, with a positive
#     control so the negatives cannot pass vacuously
#   - the guarded Coral stanza existing and the stack running without the
#     hardware (the media suite's /dev/dri drift-guard pattern)
#   - reboot durability on a real disk: both databases, the pre-seeded HA
#     storage config, and the broker credentials must all come back
#
# Documented gaps (a green run covers NONE of these):
#   - **The Coral USB TPU.** Production runs `detectors: {coral: {type:
#     edgetpu, device: usb}}`; this suite overrides that block with
#     `type: cpu`, because a missing Coral is a CRASH LOOP — the delegate
#     re-raises, the watchdog notices within 10s and SIGTERMs PID 1. So the
#     tested config differs from the deployed config in exactly the block
#     that fails hardest if it is wrong. Subtest 14 is the drift guard for
#     the part that can be checked.
#   - **Real cameras.** No RTSP sources exist here, so the stack runs with
#     `cameras: {}` — which Frigate fully supports, and which is also its own
#     first-run config. Object detection, recording and snapshots are all out
#     of reach.
#   - Hardware transcode, the IoT VLAN, and any real device.
#   - Home Assistant's OIDC: deferred in the stack itself (its custom
#     component's pip deps do not survive a container recreate offline), so
#     there is nothing here to test yet.
#   - Discovery integrations (mDNS/SSDP/DHCP) are inert on a bridge network
#     BY DESIGN and fail silently. The suite cannot tell "inert because
#     bridge" from "inert because broken", so it asserts neither.

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
    images."ghcr_io_home-assistant_home-assistant_2026_8_3"
    images."eclipse-mosquitto_2_0_22"
    images."ghcr_io_blakeblackshear_frigate_0_17_2"
    images."python_3_13-alpine" # ha-config-init + automation-init
  ];

  # The one config override this suite makes, isolated so it is impossible to
  # miss in a diff: the CPU detector instead of the Coral.
  #
  # This is not a convenience. With `type: edgetpu` and no TPU, the delegate
  # raises, Frigate's watchdog sees the dead detector process within 10s and
  # sends SIGTERM to PID 1, and `restart: unless-stopped` turns that into a
  # permanent crash loop — `cameras: {}` does not help, because detectors
  # start unconditionally. Everything else in the file is the production
  # config verbatim, and subtest 7 checks Frigate did not fall back to safe
  # mode as a result of this edit.
  frigateTestConfig = pkgs.runCommand "frigate-test-config" { } ''
    ${pkgs.python3}/bin/python3 - <<'PY'
    import os
    import re

    src = open("${../../stacks/automation/frigate.yaml}").read()

    # Replace the detectors block up to the next TOP-LEVEL key. Anchoring on
    # a column-0 key rather than on any non-space is deliberate: `(?=\S)`
    # would also stop at a column-0 COMMENT, silently truncating the match and
    # leaving `  coral:` orphaned under the replacement.
    out, n = re.subn(
        r"^detectors:\n(?:[ \t].*\n|\n)*",
        "detectors:\n  cpu:\n    type: cpu\n\n",
        src,
        count=1,
        flags=re.M,
    )
    assert n == 1, "detectors: block not found in frigate.yaml"
    assert "edgetpu" not in out, "edgetpu survived the substitution"
    assert "coral" not in out, "an orphaned coral fragment survived"
    # os.environ, not "$out": the heredoc is quoted, so the shell does not
    # expand it and python would create a file literally named $out — which
    # fails as "builder did not produce output path".
    open(os.environ["out"], "w").write(out)
    PY
  '';

  # Seeds /srv the way the real host gets it: Arcane's git sync on the live
  # machine, a store copy here.
  seedSrv = pkgs.runCommand "srv-seed-automation" { } ''
    mkdir -p $out/stacks/automation
    cp -r ${../../stacks/automation}/. $out/stacks/automation/
    chmod -R u+w $out/stacks/automation
    # The working-tree cp -r can capture a developer's locally-decrypted
    # plaintext .env (gitignored on purpose) in the world-readable store.
    rm -f $out/stacks/automation/.env
    rm -f $out/stacks/automation/.sops.env.example
    cp ${../fixtures/automation.sops.env} $out/stacks/automation/.sops.env
    # The single deliberate divergence from production — see above.
    cp ${frigateTestConfig} $out/stacks/automation/frigate.yaml
  '';
in
pkgs.testers.runNixOSTest {
  name = "automation";

  # Frigate's builtin healthcheck has a 300s start_period which `up --wait`
  # honours, Home Assistant's first boot runs migrations, and there is a
  # reboot. The driver's 3600s default would kill the VMs without running any
  # except handler, so the diag dumps would never print.
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
          # Frigate alone unpacks to several GB — it is the largest image in
          # the fleet by a distance.
          (profiles.sized {
            memoryMB = 6144;
            diskMB = 32768;
          })
          (profiles.loadImages {
            inherit pkgs;
            images = stackImages;
            beforeUnits = [ "multi-user.target" ];
          })
        ];

        # Keep Arcane out of the boot path (mk-stack-suite's rationale): its
        # image and bootstrap ordering are irrelevant here and this suite
        # already loads the fleet's biggest image. Coverage lost — the
        # decrypt -> docker-network -> bootstrap-arcane chain — is exactly
        # what checks.services covers.
        systemd.services.bootstrap-komodo.wantedBy = lib.mkForce [ ];
        # The new stack-git-sync timer would fail its clone every tick with no Forgejo here.
        systemd.timers.stack-git-sync.wantedBy = lib.mkForce [ ];

        virtualisation.cores = lib.mkForce 4;

        # /srv stays tmpfs ON PURPOSE: its post-reboot re-seed + re-decrypt is
        # itself the production shape. /mnt is a real ext4 on a persistent
        # qcow because the reboot subtest asserts DATA durability — both
        # SQLite databases, the pre-seeded .storage/http and the broker's
        # password file must survive, which tmpfs cannot represent.
        virtualisation.emptyDiskImages = [ 16384 ];
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
          # nixos/hardware-configuration.nix; keep the two in sync by hand.
          # mosquitto's two directories are 1883 because the broker drops to
          # that uid and its entrypoint does not chown all of them.
          "d /mnt/fast/homeassistant 0755 root root -"
          "d /mnt/fast/mosquitto 0755 root root -"
          "d /mnt/fast/mosquitto/config 0755 1883 1883 -"
          "d /mnt/fast/mosquitto/data 0755 1883 1883 -"
          "d /mnt/fast/frigate 0755 root root -"
          "d /mnt/fast/frigate/config 0755 root root -"
          "d /mnt/slow/frigate 0755 root root -"
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
          sqlite
          mosquitto # for the host-side MQTT round trip
        ];
      };

    # Another host on the LAN, for the negative binding assertions.
    outsider = { };
  };

  testScript = ''
    import json
    import shlex

    AUTO = "docker compose -f /srv/stacks/automation/compose.yaml -p automation"
    HA = "http://127.0.0.1:10250"
    FRIGATE = "http://127.0.0.1:10252"

    # Fixture values from tests/fixtures/automation.sops.env.
    HA_USER = "test_ha_admin"
    HA_PASS = "test_ha_password_not_secret"
    MQTT_FRIGATE_PASS = "test_frigate_mqtt_password_not_secret"
    MQTT_HA_PASS = "test_ha_mqtt_password_not_secret"

    # The gateway of the subnet pinned in compose.yaml. Home Assistant must
    # trust THIS, not 127.0.0.1: a loopback publish does not preserve the
    # source address, because docker-proxy re-dials from the bridge gateway.
    #
    # Keep it in step with the `networks.default.ipam` block in
    # stacks/automation/compose.yaml — it is outside docker's default
    # 172.17.0.0/12 pool on purpose, so that a pinned subnet cannot collide
    # with an auto-allocated one.
    GATEWAY = "10.89.250.1"

    HTTP_STORE = "/mnt/fast/homeassistant/.storage/http"
    PASSWD = "/mnt/fast/mosquitto/config/passwd"

    def diag(label):
        print("=== diagnostics: " + label + " ===")
        for cmd in [
            "docker ps -a",
            "docker logs homeassistant 2>&1 | tail -60",
            "docker logs mosquitto 2>&1 | tail -40",
            "docker logs frigate 2>&1 | tail -60",
            "docker logs automation_mqtt_init 2>&1 | tail -20",
            "docker logs automation_config_init 2>&1 | tail -20",
            "docker logs automation_init 2>&1 | tail -30",
            "ls -la /srv/stacks/automation /mnt/fast/homeassistant "
            "/mnt/fast/mosquitto/config /mnt/fast/frigate/config 2>&1",
            "cat " + HTTP_STORE + " 2>&1",
            "df -h /var/lib/docker /mnt; free -m",
        ]:
            print("--- " + cmd)
            print(services_vm.execute(cmd)[1])

    def curl(base, path, method="GET", body=None, form=None, headers=None,
             fail=False, timeout=60):
        flags = "-s -o /dev/null -w '%{http_code}'" if fail else "-sf"
        cmd = f"curl {flags} --max-time {timeout} -X {method} "
        for k, v in (headers or {}).items():
            cmd += f"-H {shlex.quote(k + ': ' + v)} "
        if form is not None:
            payload = shlex.quote("&".join(f"{k}={v}" for k, v in form.items()))
            cmd = (f"printf '%s' {payload} | " + cmd
                   + "-H 'Content-Type: application/x-www-form-urlencoded' -d @- ")
        elif body is not None:
            payload = shlex.quote(json.dumps(body))
            cmd = (f"printf '%s' {payload} | " + cmd
                   + "-H 'Content-Type: application/json' -d @- ")
        out = services_vm.succeed(cmd + shlex.quote(base + path))
        if fail:
            return int(out.strip())
        if not out.strip():
            return None
        try:
            return json.loads(out)
        except ValueError:
            return out.strip()

    start_all()

    # -----------------------------------------------------------------------
    # §6.1 boot chain + decrypt
    # -----------------------------------------------------------------------
    with subtest("decrypt-sops-envs produced a 0600 .env owned by uid 1000 (the /srv/stacks world)"):
        services_vm.wait_for_unit("multi-user.target")
        services_vm.wait_for_unit("docker-network-homelab.service")
        services_vm.wait_until_succeeds(
            "test -s /srv/stacks/automation/.env", timeout=120
        )
        stat = services_vm.succeed(
            "stat -c '%a %u:%g' /srv/stacks/automation/.env"
        ).strip()
        assert stat == "600 1000:1000", f".env is {stat}, expected 600 1000:1000"
        for k in ["HA_ADMIN_USER", "HA_ADMIN_PASSWORD", "FRIGATE_MQTT_PASSWORD",
                  "MQTT_HA_PASSWORD", "MQTT_HEALTHCHECK_PASSWORD"]:
            services_vm.succeed(f"grep -q '^{k}=.' /srv/stacks/automation/.env")

    services_vm.wait_for_unit("load-test-images.service")

    # -----------------------------------------------------------------------
    # §6.2 the broker's password file
    # -----------------------------------------------------------------------
    with subtest("mosquitto-init renders a sha512-pbkdf2 password file"):
        try:
            services_vm.succeed(AUTO + " up -d mosquitto-init")
            services_vm.wait_until_succeeds(
                "docker inspect -f '{{.State.Status}}/{{.State.ExitCode}}' "
                "automation_mqtt_init | grep -qx exited/0",
                timeout=120,
            )
        except Exception:
            diag("mosquitto-init run")
            raise
        stat = services_vm.succeed(f"stat -c '%a %u:%g' {PASSWD}").strip()
        assert stat == "600 1883:1883", f"passwd is {stat}, expected 600 1883:1883"
        passwd = services_vm.succeed(f"cat {PASSWD}")
        for user in ["frigate", "homeassistant", "healthcheck"]:
            assert f"{user}:" in passwd, f"no {user} account in the password file"
        # THE version-compatibility contract: mosquitto 2.1 defaults to
        # argon2id, which the pinned 2.0.x broker cannot read. passwd-init
        # passes -H sha512-pbkdf2 explicitly so the artifact works on both.
        assert "$7$" in passwd, (
            f"password file is not sha512-pbkdf2 hashed:\n{passwd[:200]}"
        )
        assert "argon2" not in passwd, "password file used argon2id"

    # -----------------------------------------------------------------------
    # §6.3 the Home Assistant storage config
    # -----------------------------------------------------------------------
    with subtest("ha-config-init pre-seeds .storage/http"):
        try:
            services_vm.succeed(AUTO + " up -d ha-config-init")
            services_vm.wait_until_succeeds(
                "docker inspect -f '{{.State.Status}}/{{.State.ExitCode}}' "
                "automation_config_init | grep -qx exited/0",
                timeout=120,
            )
        except Exception:
            diag("ha-config-init run")
            raise
        store = json.loads(services_vm.succeed(f"cat {HTTP_STORE}"))
        data = store["data"]
        # pending MUST be null and yaml_migration_done MUST be true: that
        # combination is what resolves to ActiveConfigType.STABLE, and a
        # `pending` config is exactly the state that gets auto-reverted after
        # five minutes.
        assert data["pending"] is None, f"pending is {data['pending']!r}"
        assert data["yaml_migration_done"] is True, "yaml_migration_done is not true"
        stable = data["stable"]
        assert stable["use_x_forwarded_for"] is True, "use_x_forwarded_for is off"
        assert stable["trusted_proxies"] == [f"{GATEWAY}/32"], (
            f"trusted_proxies is {stable['trusted_proxies']!r} — it must be the "
            f"BRIDGE GATEWAY, since a loopback publish does not preserve "
            f"127.0.0.1"
        )

    # -----------------------------------------------------------------------
    # §6.6 the stack comes up
    # -----------------------------------------------------------------------
    with subtest("compose brings up home assistant, mosquitto and frigate"):
        # automation-init is NOT in the --wait set: compose reports failure for
        # an in-scope oneshot that exited 0 unless a dependent consumes it, and
        # it has no dependents. Same trap the media/immich/books suites
        # document. The wait budget respects Frigate's 300s start_period.
        try:
            services_vm.succeed(
                AUTO + " up -d --wait --wait-timeout 900 "
                "homeassistant mosquitto frigate",
                timeout=1000,
            )
        except Exception:
            diag("compose up --wait")
            raise

    # -----------------------------------------------------------------------
    # §6.4 THE five-minute-revert regression test
    # -----------------------------------------------------------------------
    with subtest("home assistant loaded the STABLE http config, not a pending one"):
        # Since 2026.8.0 a `pending` http config is a five-minute trial that
        # auto-reverts unless an admin promotes it in the UI — and it passes
        # its healthcheck the whole time, so this log line is the only signal
        # that a headless deployment's reverse-proxy config is permanent.
        ha_log = services_vm.succeed("docker logs homeassistant 2>&1")
        assert "Using stable HTTP config" in ha_log, (
            "HA did not log 'Using stable HTTP config' — the pre-seeded store "
            "was not used, and whatever it did load may be a 5-minute trial"
        )
        assert "Using pending HTTP config" not in ha_log, (
            "HA loaded a PENDING http config: it will auto-revert in 5 minutes "
            "and never apply that config again"
        )

    # -----------------------------------------------------------------------
    # §6.5 a proxied request actually works
    # -----------------------------------------------------------------------
    with subtest("a request carrying X-Forwarded-For is accepted"):
        # The storage config is NOT re-validated on load, so a malformed
        # pre-seed fails silently rather than loudly. This is the check that
        # cannot be fooled: Caddy always sends X-Forwarded-For, and HA returns
        # 400 for every request when it sees that header without
        # use_x_forwarded_for + trusted_proxies configured for the real peer.
        proxied_status = curl(HA, "/manifest.json",
                              headers={"X-Forwarded-For": "10.0.0.9"},
                              fail=True)
        assert proxied_status == 200, (
            f"a proxied request returned HTTP {proxied_status}; 400 means HA "
            f"is not trusting the bridge gateway"
        )
        assert "not set-up for reverse proxies" not in services_vm.succeed(
            "docker logs homeassistant 2>&1"
        ), "HA logged the reverse-proxy misconfiguration error"

    # -----------------------------------------------------------------------
    # §6.7 THE Frigate safe-mode gate
    # -----------------------------------------------------------------------
    with subtest("frigate is running its real config, not safe mode"):
        # Without this the whole Frigate half of the suite passes on a totally
        # broken config: an invalid config does not crash Frigate, it starts
        # with cameras:{} and mqtt off, and reports healthy.
        cfg = curl(FRIGATE, "/api/config")
        assert cfg.get("safe_mode") is False, (
            f"frigate is in SAFE MODE — its config failed validation. "
            f"safe_mode={cfg.get('safe_mode')!r}"
        )
        frigate_log = services_vm.succeed("docker logs frigate 2>&1")
        for bad in ["Starting Frigate in safe mode", "Config Validation Errors"]:
            assert bad not in frigate_log, f"frigate log contains {bad!r}"
        # And the config it loaded is the one we shipped.
        assert cfg["mqtt"]["host"] == "mosquitto", (
            f"frigate mqtt host is {cfg['mqtt']['host']!r}"
        )

    with subtest("every container is in its contract state"):
        for name in ["homeassistant", "mosquitto", "frigate"]:
            h = services_vm.succeed(
                f"docker inspect -f '{{{{.State.Health.Status}}}}' {name}"
            ).strip()
            assert h == "healthy", f"{name} is {h!r}, expected healthy"
        for name in ["automation_mqtt_init", "automation_config_init"]:
            exit_code = services_vm.succeed(
                f"docker inspect -f '{{{{.State.ExitCode}}}}' {name}"
            ).strip()
            assert exit_code == "0", f"{name} exited {exit_code}, expected 0"

    # -----------------------------------------------------------------------
    # §6.9 headless onboarding
    # -----------------------------------------------------------------------
    with subtest("automation-init onboards home assistant"):
        try:
            services_vm.succeed(AUTO + " up -d automation-init")
            services_vm.wait_until_succeeds(
                "docker inspect -f '{{.State.Status}}/{{.State.ExitCode}}' "
                "automation_init | grep -qx exited/0",
                timeout=300,
            )
        except Exception:
            diag("automation-init run")
            raise
        seed_log = services_vm.succeed("docker logs automation_init 2>&1")
        assert "CHANGE: home assistant owner" in seed_log, (
            f"automation-init logged no owner-creation line:\n{seed_log}"
        )

    with subtest("the seeded owner logs in with the fixture credentials"):
        # HA's login is a multi-step flow; the first step is enough to prove
        # the credentials reached it, and it is the step that would 400 if the
        # proxy config were wrong. The credentials exist only in the encrypted
        # fixture, so this proves sops -> .env -> env_file end to end.
        flow = curl(HA, "/auth/login_flow", "POST", {
            "client_id": "http://127.0.0.1:8123/",
            "handler": ["homeassistant", None],
            "redirect_uri": "http://127.0.0.1:8123/",
        })
        flow_id = (flow or {}).get("flow_id")
        assert flow_id, f"no flow_id in {flow!r}"
        res = curl(HA, f"/auth/login_flow/{flow_id}", "POST", {
            "client_id": "http://127.0.0.1:8123/",
            "username": HA_USER,
            "password": HA_PASS,
        })
        auth_code = (res or {}).get("result")
        assert auth_code, (
            f"login with the fixture credentials did not yield a code: {res!r}"
        )
        # Exchanged here because the config-entry assertions below need a
        # bearer token, and this is the only place one can be obtained.
        tok = curl(HA, "/auth/token", "POST", form={
            "grant_type": "authorization_code",
            "client_id": "http://127.0.0.1:8123/",
            "code": auth_code,
        })
        ha_token = (tok or {}).get("access_token")
        assert ha_token, f"token exchange returned no access_token: {tok!r}"

    with subtest("automation-init created the mqtt config entry"):
        seed_log = services_vm.succeed("docker logs automation_init 2>&1")
        assert "CHANGE: home assistant mqtt config entry created" in seed_log, (
            f"automation-init did not create the mqtt config entry:\n{seed_log}"
        )

    # -----------------------------------------------------------------------
    # §6.10 the MQTT round trip — the reason the stack exists
    # -----------------------------------------------------------------------
    with subtest("MQTT round trip with authentication on"):
        # Publish as frigate, receive as homeassistant — both fixture
        # credentials, both hashed into the broker's password file by the
        # init container. Probed from the host through the loopback publish.
        services_vm.succeed(
            "mosquitto_sub -h 127.0.0.1 -p 10251 "
            f"-u homeassistant -P {shlex.quote(MQTT_HA_PASS)} "
            "-t automation/suite -C 1 -W 20 > /tmp/mqtt-received.txt 2>/dev/null &"
        )
        services_vm.sleep(2)
        services_vm.succeed(
            "mosquitto_pub -h 127.0.0.1 -p 10251 "
            f"-u frigate -P {shlex.quote(MQTT_FRIGATE_PASS)} "
            "-t automation/suite -m hello-from-frigate"
        )
        services_vm.wait_until_succeeds(
            "grep -q hello-from-frigate /tmp/mqtt-received.txt", timeout=30
        )

    with subtest("the broker refuses anonymous and wrong-password clients"):
        # Otherwise the positive above proves only that a broker exists.
        # NO -W here: mosquitto_pub does not accept it (it is a sub-only
        # option) and exits 1 on "Unknown option" BEFORE opening a socket —
        # which would make both of these pass against a wide-open broker.
        # Without the flag they fail on the CONNACK, which is the point.
        services_vm.fail(
            "mosquitto_pub -h 127.0.0.1 -p 10251 -t automation/suite -m nope"
        )
        services_vm.fail(
            "mosquitto_pub -h 127.0.0.1 -p 10251 -u frigate -P wrongpassword "
            "-t automation/suite -m nope"
        )

    with subtest("frigate is actually connected to the broker"):
        # Proves BOTH the {FRIGATE_MQTT_PASSWORD} substitution and the
        # service-name path — Frigate reaching `mosquitto:1883` over the
        # compose network rather than a host port.
        #
        # Asserted by SUBSCRIBING to frigate/available rather than by grepping
        # the log for "mqtt": that message is Frigate's own birth/LWT topic, so
        # it exists only if Frigate authenticated to the broker. A log grep for
        # a substring that appears in a dozen unrelated lines would be
        # unfalsifiable.
        available = services_vm.succeed(
            "mosquitto_sub -h 127.0.0.1 -p 10251 "
            f"-u homeassistant -P {shlex.quote(MQTT_HA_PASS)} "
            "-t 'frigate/available' -C 1 -W 60 2>/dev/null"
        ).strip()
        assert available == "online", (
            f"frigate/available is {available!r}, expected 'online' — frigate "
            f"did not authenticate to the broker"
        )

    with subtest("home assistant is actually connected to the broker"):
        # THE assertion that catches a silently-unconfigured MQTT integration.
        # `mqtt:` in configuration.yaml is NOT a valid config key any more (its
        # schema takes only platform names), so a YAML-configured broker logs
        # "Invalid config", HA starts anyway, serves a healthy /manifest.json,
        # and simply never connects. Nothing else in this suite would notice.
        ha_log = services_vm.succeed("docker logs homeassistant 2>&1")
        assert "Invalid config for 'mqtt'" not in ha_log, (
            "home assistant rejected an mqtt YAML block — the broker "
            "connection has to be a config ENTRY, not YAML"
        )
        entries = curl(HA, "/api/config/config_entries/entry", "GET", None,
                       headers={"Authorization": f"Bearer {ha_token}"})
        mqtt_entries = [e for e in (entries or []) if e.get("domain") == "mqtt"]
        assert len(mqtt_entries) == 1, (
            f"expected exactly one mqtt config entry, found "
            f"{len(mqtt_entries)}: {mqtt_entries!r}"
        )
        assert mqtt_entries[0].get("state") == "loaded", (
            f"the mqtt config entry is {mqtt_entries[0].get('state')!r}, "
            f"not loaded"
        )

    # -----------------------------------------------------------------------
    # §6.12 publishing posture
    # -----------------------------------------------------------------------
    with subtest("published ports answer on loopback and nowhere else"):
        # Positive control first: without it a node-naming regression makes
        # every fail() below pass vacuously.
        outsider.succeed("nc -z -w 5 services-vm 22")
        for port in [10250, 10251, 10252]:
            services_vm.wait_for_open_port(port, addr="127.0.0.1")
            outsider.fail(f"nc -z -w 5 services-vm {port}")

    with subtest("frigate does not publish its unauthenticated admin port"):
        # Port 5000 returns success with remote-role: admin for ANY request.
        # It is in the image's EXPOSE list and 8971 is not, so publishing the
        # wrong one is a very easy mistake to make.
        ports = json.loads(services_vm.succeed(
            "docker inspect -f '{{json .NetworkSettings.Ports}}' frigate"
        ))
        published = {p for p, binds in ports.items() if binds}
        assert published == {"8971/tcp"}, (
            f"frigate publishes {published} — it must publish 8971 and ONLY "
            f"8971 (5000 is an unauthenticated forced-admin bypass)"
        )

    # -----------------------------------------------------------------------
    # §6.14 the guarded Coral stanza (media's /dev/dri drift-guard pattern)
    # -----------------------------------------------------------------------
    with subtest("the guarded Coral stanza exists and degrades in a VM"):
        # The TPU is untestable here, but losing the stanza silently would
        # cost the Coral on the real host — and using `devices:` instead would
        # make the container refuse to start wherever the node is absent.
        services_vm.succeed(
            "grep -qF -- '- /dev/bus/usb:/dev/bus/usb' "
            "/srv/stacks/automation/compose.yaml"
        )
        services_vm.succeed(
            "grep -qF \"c 189:* rmw\" /srv/stacks/automation/compose.yaml"
        )
        # And the guard works: no Coral in this VM, container runs anyway.
        services_vm.succeed("docker exec frigate test -d /dev/bus/usb")

    # -----------------------------------------------------------------------
    # §6.13 the backup contract
    # -----------------------------------------------------------------------
    with subtest("the SQLite paths backup-prepare.sh dumps exist and dump"):
        for name, src in [
            ("homeassistant", "/mnt/fast/homeassistant/home-assistant_v2.db"),
            ("frigate", "/mnt/fast/frigate/config/frigate.db"),
        ]:
            services_vm.wait_until_succeeds(f"test -f {src}", timeout=180)
            services_vm.succeed(
                f"sqlite3 {src} \".backup '/tmp/{name}.sqlite'\""
            )
            services_vm.succeed(f"test -s /tmp/{name}.sqlite")

    # -----------------------------------------------------------------------
    # §6.15 idempotence under Arcane redeploys
    # -----------------------------------------------------------------------
    with subtest("re-running the oneshots is a no-op"):
        # mosquitto-init is deliberately ABSENT from this list: mosquitto_passwd
        # salts every hash, so its output is non-deterministic and the only way
        # to answer "did anything change?" would be to store a digest of the
        # input passwords on a backed-up volume. It regenerates every run by
        # design; see stacks/automation/passwd-init.sh.
        for service, container in [
            ("ha-config-init", "automation_config_init"),
            ("automation-init", "automation_init"),
        ]:
            services_vm.succeed(f"docker rm -f {container}")
            services_vm.succeed(AUTO + f" up -d {service}")
            services_vm.wait_until_succeeds(
                "docker inspect -f '{{.State.Status}}/{{.State.ExitCode}}' "
                f"{container} | grep -qx exited/0",
                timeout=300,
            )
            run_log = services_vm.succeed(f"docker logs {container} 2>&1")
            assert "CHANGE:" not in run_log, (
                f"second {service} run was not a no-op:\n{run_log}"
            )

    # -----------------------------------------------------------------------
    # §6.16 reboot survival on persistent storage
    # -----------------------------------------------------------------------
    with subtest("the stack returns after a reboot with its data intact"):
        # shutdown() + start(), NOT reboot(): the driver runs qemu with
        # -no-reboot, so an in-guest reboot terminates the VM.
        services_vm.shutdown()
        services_vm.start()
        services_vm.wait_for_unit("multi-user.target")
        services_vm.wait_until_succeeds(
            "test -s /srv/stacks/automation/.env", timeout=120
        )
        try:
            for port in [10250, 10251, 10252]:
                services_vm.wait_for_open_port(port, addr="127.0.0.1",
                                               timeout=900)
        except Exception:
            diag("post-reboot")
            raise
        # The pre-seeded storage config survived AND is still stable — a
        # revert would have rewritten it.
        store = json.loads(services_vm.succeed(f"cat {HTTP_STORE}"))
        assert store["data"]["pending"] is None, "a pending http config appeared"
        ha_log = services_vm.succeed("docker logs homeassistant 2>&1")
        assert "Using stable HTTP config" in ha_log, (
            "post-reboot HA did not load the stable http config"
        )
        # The broker credentials survived, so the event chain still works.
        services_vm.succeed(
            "mosquitto_pub -h 127.0.0.1 -p 10251 "
            f"-u frigate -P {shlex.quote(MQTT_FRIGATE_PASS)} "
            "-t automation/suite -m after-reboot"
        )
        # And Frigate did not come back in safe mode.
        cfg = curl(FRIGATE, "/api/config")
        assert cfg.get("safe_mode") is False, "frigate rebooted into safe mode"
  '';
}
