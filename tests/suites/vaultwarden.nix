# Vaultwarden suite: one container, and the most consequential assertions in
# the campaign per line of test code.
#
# Hand-written rather than mk-stack-suite because the thing that has to be
# proven here is not "it came up" — it is that the ADMIN_TOKEN survived the
# journey from the encrypted fixture into the process unmangled, which nothing
# generic can check.
#
# Genuinely under test:
#   - 🚨 **The `$`-mangling regression.** Docker Compose interpolates values
#     read from env_file, so a bare argon2 PHC arrives with `$argon2id`, `$v`
#     and `$m` expanded to nothing — a DIFFERENT, shorter string (verified
#     empirically; finding #30). Vaultwarden dispatches on a literal `$argon2`
#     prefix test, so the mangled value falls through to a PLAINTEXT COMPARE
#     and /admin rejects everything, with the only clue a startup `[NOTICE]`
#     about "a plain text ADMIN_TOKEN" nobody chose. The suite checks the value
#     as the CONTAINER sees it and then performs a real login round trip,
#     because only the round trip separates "configured" from "mangled".
#   - The vault's own database really is where backup-prepare.sh looks, and it
#     really is in WAL mode — which is why the `.backup` dump is the restorable
#     copy and the raw file in the /mnt/fast include set is not. `sqlite_backup`
#     returns 0 for a MISSING source, so a wrong path would back up nothing
#     forever with a clean exit (finding #25's class; this is exactly how the
#     Karakeep line failed).
#   - `rsa_key.pem` exists. It is the JWT signing key, it is NOT in the dump,
#     and a restore without it logs out every client at once and re-prompts
#     2FA. Asserting its existence is what stops it being forgotten.
#   - Signups really are closed, which is the shipped state and the reason
#     there is no init container here.
#   - loopback-only publishing from another host, with a positive control.
#   - reboot durability on a real disk.
#
# Documented gaps (a green run covers NONE of these):
#   - **Account creation and every client.** Bitwarden registration is
#     client-side cryptography — master-key derivation, a wrapped symmetric
#     key, an RSA keypair — and reimplementing it in a test would risk proving
#     that a vault no real client can open is "working". The first account is
#     an operator step ON PURPOSE (see .sops.env.example), so nothing here logs
#     into a vault.
#   - **SSO.** Ships off; discovery is lazy, so the off-state is all there is
#     to assert.
#   - **The /admin forward-auth layer.** Caddy imports (protected) for
#     `/admin*` only; that hop needs the VPS outpost and is covered by
#     tests/suites/forward-auth.nix's contract, not here. What this suite
#     proves is the OTHER half of that belt-and-braces arrangement — that the
#     token still works on its own.

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
    images."vaultwarden_server_1_37_2"
  ];

  seedSrv = pkgs.runCommand "srv-seed-vaultwarden" { } ''
    mkdir -p $out/stacks/vaultwarden
    cp -r ${../../stacks/vaultwarden}/. $out/stacks/vaultwarden/
    chmod -R u+w $out/stacks/vaultwarden
    # The working-tree cp -r can capture a developer's locally-decrypted
    # plaintext .env (gitignored on purpose) in the world-readable store.
    rm -f $out/stacks/vaultwarden/.env
    rm -f $out/stacks/vaultwarden/.sops.env.example
    cp ${../fixtures/vaultwarden.sops.env} $out/stacks/vaultwarden/.sops.env
  '';
in
pkgs.testers.runNixOSTest {
  name = "vaultwarden";

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
            memoryMB = 3072;
            diskMB = 12288;
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

        # /srv is tmpfs so its post-reboot re-seed + re-decrypt is the
        # production shape; /mnt is a real ext4 on a persistent qcow because
        # the reboot subtest asserts DATA durability.
        virtualisation.emptyDiskImages = [ 4096 ];
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
          # The SAME rule production declares in
          # nixos/hardware-configuration.nix. root:root is correct: the debian
          # image declares no USER and start.sh execs the binary directly.
          "d /mnt/fast/vaultwarden 0755 root root -"
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
        ];
      };

    outsider = { };
  };

  testScript = ''
    import shlex

    VW = "docker compose -f /srv/stacks/vaultwarden/compose.yaml -p vaultwarden"
    BASE = "http://127.0.0.1:10400"
    DATA = "/mnt/fast/vaultwarden"

    # The PLAINTEXT the fixture's argon2 PHC was computed over. The PHC itself
    # lives only in the encrypted fixture; if the hash in there is ever
    # regenerated, this must be regenerated with it.
    ADMIN_PASS = "test_vaultwarden_admin_token_not_secret"

    # What a correctly-delivered PHC must still start with once the container
    # has it. Mangled forms lose exactly this prefix — see the subtest.
    PHC_PREFIX = "$argon2id$v=19$m=65540,t=3,p=4$"

    def diag(label):
        print("=== diagnostics: " + label + " ===")
        for cmd in [
            "docker ps -a",
            "docker logs vaultwarden 2>&1 | tail -60",
            "docker inspect --format '{{.State.Health.Status}}' vaultwarden 2>&1",
            f"ls -la {DATA} 2>&1",
            "df -h /var/lib/docker /mnt; free -m",
        ]:
            print("--- " + cmd)
            print(services_vm.execute(cmd)[1])

    start_all()

    # -----------------------------------------------------------------------
    # boot chain + decrypt
    # -----------------------------------------------------------------------
    with subtest("decrypt-sops-envs produced a 0600 .env owned by uid 1000 (the /srv/stacks world)"):
        services_vm.wait_for_unit("multi-user.target")
        services_vm.wait_for_unit("docker-network-homelab.service")
        services_vm.wait_until_succeeds(
            "test -s /srv/stacks/vaultwarden/.env", timeout=120
        )
        stat = services_vm.succeed(
            "stat -c '%a %u:%g' /srv/stacks/vaultwarden/.env"
        ).strip()
        assert stat == "600 1000:1000", f".env is {stat}, expected 600 1000:1000"
        # Present and EMPTY is the shipped OIDC state, not an oversight.
        for k in ["SSO_CLIENT_ID", "SSO_CLIENT_SECRET"]:
            services_vm.succeed(f"grep -qx '{k}=' /srv/stacks/vaultwarden/.env")

    with subtest("the decrypted .env keeps the PHC SINGLE-QUOTED"):
        # sops round-trips the quotes as part of the value. If a future edit
        # drops them, the container gets a mangled token and /admin dies — so
        # catch it here, one layer before the symptom.
        line = services_vm.succeed(
            "grep '^ADMIN_TOKEN=' /srv/stacks/vaultwarden/.env"
        ).strip()
        assert line.startswith("ADMIN_TOKEN='") and line.endswith("'"), (
            f"ADMIN_TOKEN is not single-quoted in the decrypted .env: {line[:40]}... "
            "Compose interpolates env_file values, so an unquoted argon2 PHC "
            "loses $argon2id/$v/$m and arrives as a different string."
        )

    services_vm.wait_for_unit("load-test-images.service")

    # -----------------------------------------------------------------------
    # the stack comes up
    # -----------------------------------------------------------------------
    with subtest("compose up reaches healthy on the image's own probe"):
        # Not overridden anywhere: this is the first inherited healthcheck in
        # the campaign that is honest. /alive takes a DbConn request guard
        # specifically so the probe verifies the database connection, so
        # reaching healthy here already proves SQLite opened.
        try:
            services_vm.succeed(f"{VW} up -d --wait --wait-timeout 600")
        except Exception:
            diag("compose up failed")
            raise

    # -----------------------------------------------------------------------
    # 🚨 the $-mangling regression, checked at both layers
    # -----------------------------------------------------------------------
    with subtest("the container received the PHC intact, not an expanded ruin"):
        env = services_vm.succeed(
            "docker inspect --format "
            "'{{range .Config.Env}}{{println .}}{{end}}' vaultwarden"
        )
        tok = [l for l in env.splitlines() if l.startswith("ADMIN_TOKEN=")]
        assert len(tok) == 1, f"expected exactly one ADMIN_TOKEN, got {tok}"
        value = tok[0][len("ADMIN_TOKEN="):]
        assert value.startswith(PHC_PREFIX), (
            f"ADMIN_TOKEN reached the container as {value[:32]!r}. "
            "It has been interpolated: Compose expands $argon2id/$v/$m in "
            "env_file values unless the value is SINGLE-quoted. Vaultwarden "
            "will now compare passwords against this string in plaintext and "
            "/admin will reject everything, logging only a [NOTICE] about a "
            "plain text ADMIN_TOKEN."
        )
        # Belt and braces: prove the quotes themselves did not survive INTO
        # the value, which would fail the argon2 prefix test just as badly.
        assert not value.startswith("'"), f"quotes leaked into the value: {value[:16]!r}"

    with subtest("vaultwarden did NOT fall back to a plaintext token"):
        # The one log line that would betray a mangled value. Asserting its
        # ABSENCE is cheap and names the failure precisely if it ever appears.
        logs = services_vm.succeed("docker logs vaultwarden 2>&1")
        assert "plain text ADMIN_TOKEN" not in logs, (
            "vaultwarden reports a plain text ADMIN_TOKEN — the argon2 prefix "
            f"test failed, so the value was mangled in transit:\n{logs[-2000:]}"
        )
        assert "has an empty value" not in logs, logs[-2000:]

    with subtest("/admin accepts the real token — the round trip"):
        # The only assertion that distinguishes "correctly configured" from
        # every mangling mode: a POST that yields a session rather than a
        # re-render of the login form.
        out = services_vm.succeed(
            "curl -sS -i --max-time 30 -X POST "
            f"-d {shlex.quote('token=' + ADMIN_PASS)} {BASE}/admin"
        )
        assert "VW_ADMIN" in out, (
            f"POST /admin set no admin session cookie:\n{out[:1200]}"
        )

    with subtest("/admin REJECTS a wrong token — the control"):
        # Without this, the previous subtest would pass against an /admin that
        # had been disabled into accepting anything.
        out = services_vm.succeed(
            "curl -sS -i --max-time 30 -X POST "
            "-d 'token=definitely-not-the-token' " + BASE + "/admin"
        )
        assert "VW_ADMIN" not in out, (
            f"POST /admin accepted a wrong token:\n{out[:1200]}"
        )

    # -----------------------------------------------------------------------
    # the shipped closed state
    # -----------------------------------------------------------------------
    with subtest("signups are closed"):
        env = services_vm.succeed(
            "docker inspect --format "
            "'{{range .Config.Env}}{{println .}}{{end}}' vaultwarden"
        )
        assert "SIGNUPS_ALLOWED=false" in env, env
        # And behaviourally, not just structurally. A 4xx here is the point;
        # note a validation 400 would also satisfy it, which is why the env
        # assertion above is kept alongside.
        code = int(services_vm.succeed(
            "curl -s -o /dev/null -w '%{http_code}' --max-time 30 "
            "-H 'Content-Type: application/json' "
            "-d '{\"email\":\"nobody@test.invalid\",\"masterPasswordHash\":\"x\",\"key\":\"x\"}' "
            f"{BASE}/identity/accounts/register"
        ).strip())
        assert code >= 400, f"registration returned {code} with signups closed"

    # -----------------------------------------------------------------------
    # the backup contract
    # -----------------------------------------------------------------------
    with subtest("the database is where backup-prepare.sh looks"):
        # sqlite_backup returns 0 for a MISSING source, so without this the
        # vault's only dump could be a permanent silent no-op — which is
        # precisely how the Karakeep line failed for months.
        services_vm.succeed(f"test -f {DATA}/db.sqlite3")

    with subtest("rsa_key.pem exists — the half the dump does not cover"):
        # The JWT signing key. Not in the dump; covered only by the raw
        # /mnt/fast include set. A restore without it logs out every client at
        # once and re-prompts 2FA.
        services_vm.succeed(f"test -f {DATA}/rsa_key.pem")

    with subtest("the database is in WAL mode, so the dump is the real copy"):
        mode = services_vm.succeed(
            f"sqlite3 {DATA}/db.sqlite3 'PRAGMA journal_mode;'"
        ).strip()
        assert mode == "wal", (
            f"journal_mode is {mode!r}, expected 'wal'. ENABLE_DB_WAL defaults "
            "true; if that has changed, the reasoning behind the sqlite_backup "
            "line (a raw copy of a live WAL database can snapshot torn) needs "
            "revisiting rather than silently not applying."
        )

    with subtest("sqlite_backup's actual command produces a usable copy"):
        # The literal operation backup-prepare.sh performs, not an approximation.
        services_vm.succeed(
            f"sqlite3 {DATA}/db.sqlite3 \".backup '/tmp/vw.sqlite'\""
        )
        out = services_vm.succeed(
            "sqlite3 /tmp/vw.sqlite \"select count(*) from sqlite_master\""
        ).strip()
        assert int(out) > 0, f"the dump has no schema: {out}"

    # -----------------------------------------------------------------------
    # publishing
    # -----------------------------------------------------------------------
    with subtest("10400 is loopback-only, with a positive control"):
        ip = services_vm.succeed(
            "ip -4 -o addr show eth1 | awk '{print $4}' | cut -d/ -f1"
        ).strip()
        outsider.wait_for_unit("network.target")
        outsider.fail(f"curl -s --max-time 10 http://{ip}:10400/alive >/dev/null")
        outsider.succeed(f"ping -c1 -W5 {ip} >/dev/null")

    # -----------------------------------------------------------------------
    # durability
    # -----------------------------------------------------------------------
    with subtest("state survives a reboot"):
        # shutdown()+start(), not reboot(): the driver runs qemu with
        # -no-reboot, so reboot() kills the VM.
        services_vm.shutdown()
        services_vm.start()
        services_vm.wait_for_unit("multi-user.target")
        services_vm.wait_until_succeeds(
            "test -s /srv/stacks/vaultwarden/.env", timeout=180
        )
        services_vm.wait_for_unit("load-test-images.service")
        services_vm.succeed(f"{VW} up -d --wait --wait-timeout 600")
        services_vm.succeed(f"test -f {DATA}/db.sqlite3")
        services_vm.succeed(f"test -f {DATA}/rsa_key.pem")
        # And the token still works, which proves the .env was re-decrypted
        # from the encrypted fixture rather than surviving in tmpfs.
        out = services_vm.succeed(
            "curl -sS -i --max-time 30 -X POST "
            f"-d {shlex.quote('token=' + ADMIN_PASS)} {BASE}/admin"
        )
        assert "VW_ADMIN" in out, out[:1200]
  '';
}
