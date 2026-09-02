# Wealthfolio suite — hand-written, though the stack (one container, no
# oneshot init) would fit mk-stack-suite: the generic harness proves the
# container goes healthy, and this stack's healthcheck going green is
# precisely the signal that cannot be trusted. /api/v1/healthz is a static
# "ok" — it cannot see the one failure this stack is actually exposed to,
# a password hash mangled in transit — so the honest signal is a REAL login
# with the fixture password, plus negative-control containers for the traps
# that only fire at boot.
#
# Genuinely under test:
#   - 🚨 **The Argon2id PHC survives decrypt -> compose-interpolate, end to
#     end.** The hash is made of '$' (finding #30, vaultwarden's ADMIN_TOKEN
#     byte for byte); the fixture single-quotes it and the proof is a login
#     that actually succeeds. Asserted negatively too: a deliberately
#     mangled hash (exactly what unquoted interpolation delivers) is
#     BOOT-FATAL at 3.7.0 — the server exits with a parse error that names
#     WF_AUTH_PASSWORD_HASH and the single-quote fix (measured; an earlier
#     draft of this suite expected the quiet-lockout semantics of older
#     auth.rs, where the hash was only parsed at login and the correct
#     password 404ed under a green healthcheck). Loud is better, and this
#     control notices if a bump ever regresses it back to quiet.
#   - 🚨 **OIDC discovery is BOOT-FATAL** (bake-off UNVERIFIED item, now
#     measured): OidcManager::discover() runs once at startup and panics on
#     failure, and unlike Ghostfolio there is NO URL-override escape hatch.
#     Pinned with a dead-issuer container so a version bump that changes
#     this behaviour is noticed. This is WHY the stack ships OIDC OFF.
#   - 🚨 **The allowlist fails closed**: OIDC configured with no
#     WF_OIDC_ALLOWED_* and no WF_OIDC_ALLOW_ANY refuses to boot rather
#     than admitting every IdP account.
#   - 🚨 **The finding-#11 race is LOUD here**: with no .env at all the
#     server panics on the missing WF_SECRET_KEY — the opposite of
#     tandoor's silent SQLite fallback, and worth pinning as a property.
#   - **The db lands where backup-prepare.sh will look** —
#     /mnt/fast/wealthfolio/wealthfolio.db, owned 1000 — because
#     sqlite_backup returns 0 for a missing source (finding #25) and would
#     otherwise no-op forever once the line is added.
#   - **10309 is unreachable from another machine.**
#
# Documented gaps:
#   - **Market data.** The VM has no route to the internet, so quote
#     fetching is never exercised; boot and login provably do not need it,
#     which is the property the fleet cares about.
#   - **OIDC turn-on.** Needs the VPS + an Authentik client secret; only
#     the OFF state and the boot-fatal trap are covered.
#   - **CORS.** WF_CORS_ALLOW_ORIGINS is browser-enforced; curl cannot see
#     a wrong origin. The compose comment carries the warning.

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
    images."wealthfolio_wealthfolio_3_7_0"
  ];

  fixture = ../fixtures/wealthfolio.sops.env;

  seedSrv = pkgs.runCommand "srv-seed-wealthfolio" { } ''
    mkdir -p $out/stacks/wealthfolio
    cp -r ${../../stacks/wealthfolio}/. $out/stacks/wealthfolio/
    chmod -R u+w $out/stacks/wealthfolio
    # A locally-decrypted plaintext .env is gitignored but would still be
    # captured by cp -r into the world-readable store.
    rm -f $out/stacks/wealthfolio/.env
    rm -f $out/stacks/wealthfolio/.sops.env.example $out/stacks/wealthfolio/.sops.env
    cp ${fixture} $out/stacks/wealthfolio/.sops.env
  '';

  # /mnt tmpfiles rules from the SAME generated file the real host imports
  # (nixos/stack-dirs.nix), never hand-copied — the beszel/mk-stack-suite
  # pattern. Ownership is the point here: the image is USER 1000 with no
  # chown, so a root-owned /mnt/fast/wealthfolio is fatal, and a suite that
  # hardcoded the right owner would assert its own fixture.
  stackMntRoots = [ "/mnt/fast/wealthfolio" ];
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
        "wealthfolio suite: nixos/stack-dirs.nix has no rule for "
        + lib.concatStringsSep ", " missingRoots
        + " — add the STACK_NOTES/DIR_NOTES entries and re-run nixos/generate-stack-dirs.sh"
      );
in
pkgs.testers.runNixOSTest {
  name = "wealthfolio";

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
          description = "Seed /srv with the wealthfolio stack (test only)";
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

    # curl EXPLICITLY: the outsider only ever runs it inside .fail(), and a
    # node without curl makes that negative pass vacuously — the probe would
    # fail because the binary is missing, not because the port is closed.
    outsider =
      { pkgs, ... }:
      {
        environment.systemPackages = [ pkgs.curl ];
      };
  };

  testScript = ''
    WF = "docker compose -f /srv/stacks/wealthfolio/compose.yaml -p wealthfolio"
    BASE = "http://127.0.0.1:10309"
    IMG = "wealthfolio/wealthfolio:3.7.0"
    PASSWORD = "test_wealthfolio_password_not_secret"
    # The fixture's WF_SECRET_KEY, reused verbatim by the throwaway
    # negative-control containers (any valid 32-byte base64 would do).
    SECRET = "Ez4yIgxjDHnfiqpoXSfC17r1imQF2AMz465xzy+0OvA="
    # 🚨 The fixture's PHC with every '$var' deleted — byte for byte what
    # compose env_file interpolation delivers when the operator forgets the
    # single quotes ($argon2id, $v, $m, $<salt>, $Q each expand to empty;
    # finding #30's measured shape). Non-empty, so auth counts as
    # "configured" — and at 3.7.0 the startup parse refuses it outright
    # (see the boot-fatal control below).
    MANGLED = "=19=65536,t=3,p=4/xYfyhqDT6hDpyg7RWi3WhVQ0SKSyEMZnxiJmambjY"
    JAR = "/tmp/wf-cookies.txt"

    def dump_diag():
        for label, cmd in [
            ("compose ps", f"{WF} ps -a"),
            ("app logs", "docker logs wealthfolio 2>&1 | tail -50"),
            ("decrypt journal",
             "journalctl -u decrypt-sops-envs --no-pager -o cat | tail -20"),
            ("data dir", "ls -la /mnt/fast/wealthfolio"),
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
            # oneshot on a minutely timer, so waiting on the unit races its
            # inactive-after-success state (mk-stack-suite's rule).
            services_vm.wait_until_succeeds(
                "test -s /srv/stacks/wealthfolio/.env", timeout=90
            )
            mode = services_vm.succeed(
                "stat -c %a /srv/stacks/wealthfolio/.env"
            ).strip()
            assert mode == "600", f".env is mode {mode}, expected 600"

        with subtest("the stack comes up healthy, offline"):
            # One container, no oneshot: --wait is safe here (finding #39
            # does not apply). No route to the internet exists in this VM,
            # so this also proves boot needs no market data and no registry.
            services_vm.succeed(f"{WF} up -d --wait --wait-timeout 300")
            services_vm.wait_until_succeeds(
                f"curl -fsS --max-time 10 {BASE}/api/v1/healthz | grep -qx ok",
                timeout=120,
            )

        with subtest("the db landed where backup-prepare.sh will look"):
            # sqlite_backup returns 0 for a MISSING source (finding #25) —
            # once `sqlite_backup wealthfolio
            # /mnt/fast/wealthfolio/wealthfolio.db` is in backup-prepare.sh,
            # this assertion is what keeps it from no-opping forever after
            # an upstream path change.
            services_vm.succeed("test -f /mnt/fast/wealthfolio/wealthfolio.db")
            uid = services_vm.succeed(
                "stat -c %u /mnt/fast/wealthfolio/wealthfolio.db"
            ).strip()
            assert uid == "1000", f"db owned by uid {uid}, expected 1000"

        with subtest("auth is armed: password login advertised, OIDC off"):
            # camelCase, measured against the pinned 3.7.0:
            # {"requiresPassword":true,"oidcEnabled":false}
            services_vm.succeed(
                f"curl -fsS --max-time 10 {BASE}/api/v1/auth/status "
                "| jq -e '.requiresPassword == true and .oidcEnabled == false'"
            )

        with subtest("🚨 the argon2 PHC survived decrypt+interpolation: a real login"):
            # THE assertion of this suite: only a login proves the hash that
            # reached the container is the one that was encrypted. Wrong
            # password first — must be a 401, which also proves the hash
            # parsed as a valid PHC (a malformed one never boots at all —
            # see the mangled control below).
            code = services_vm.succeed(
                "curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "
                "-X POST -H 'Content-Type: application/json' "
                "-d '{\"password\":\"wrong-password\"}' "
                f"{BASE}/api/v1/auth/login"
            ).strip()
            assert code == "401", f"wrong password gave {code}, expected 401"
            services_vm.succeed(
                f"curl -fsS --max-time 10 -c {JAR} "
                "-X POST -H 'Content-Type: application/json' "
                "-d '{\"password\":\"" + PASSWORD + "\"}' "
                f"{BASE}/api/v1/auth/login "
                "| jq -e '.authenticated == true'"
            )
            services_vm.succeed(f"grep -q wf_session {JAR}")
            # The cookie round trip (WF_COOKIE_SECURE=auto: no
            # X-Forwarded-Proto here, so the cookie is not Secure and plain
            # http may carry it — behind Caddy it flips to Secure).
            services_vm.succeed(
                f"curl -fsS --max-time 10 -b {JAR} {BASE}/api/v1/auth/me "
                "| jq -e '.authenticated == true'"
            )
            out = services_vm.execute(
                f"curl -sS --max-time 10 {BASE}/api/v1/auth/me"
            )[1]
            assert '"authenticated":true' not in out.replace(" ", ""), (
                "an anonymous /auth/me claims to be authenticated:\n" + out
            )

        with subtest("🚨 a mangled hash is BOOT-FATAL, and the error names the fix"):
            # The unquoted-.env failure, reproduced on purpose. Measured
            # semantics at 3.7.0: the hash is parsed at STARTUP, and a
            # string that is not a valid Argon2id PHC aborts the server
            # with "Failed to parse WF_AUTH_PASSWORD_HASH ... single-quote
            # it or double every '$'" — upstream made finding #30 loud.
            # (An earlier auth.rs parsed only at login: green healthcheck,
            # password advertised, correct password 404ed — the quiet
            # lockout this control was first written for. If this subtest
            # ever fails with the server RUNNING, that behaviour is back;
            # the property that must hold either way is "correct password
            # does NOT get a session".)
            # (CORS set explicitly anyway: hash present = auth enabled, and
            # the default "*" is its own boot panic — which would pass this
            # control for the wrong reason and rot it.)
            rc, out = services_vm.execute(
                "docker run --rm --name bkg-wf-mangled "
                f"-e WF_SECRET_KEY='{SECRET}' "
                f"-e WF_AUTH_PASSWORD_HASH='{MANGLED}' "
                "-e WF_CORS_ALLOW_ORIGINS=http://127.0.0.1:19309 "
                f"{IMG} 2>&1"
            )
            assert rc != 0, (
                "a mangled WF_AUTH_PASSWORD_HASH booted — the loud-at-start "
                "parse has regressed to the old quiet lockout; re-read "
                f"auth.rs before trusting a green healthcheck:\n{out}"
            )
            assert "WF_AUTH_PASSWORD_HASH" in out, out
            assert "single-quote" in out, out

        with subtest("🚨 OIDC discovery is BOOT-FATAL — why the stack ships it OFF"):
            # Ghostfolio's trap without Ghostfolio's escape hatch: discovery
            # runs once at startup, panics on failure, and there are no
            # OIDC_*_URL overrides to skip it. A dead issuer must abort the
            # container, not degrade. The allowlist is set so this control
            # reaches discovery rather than the fail-closed check below.
            rc, out = services_vm.execute(
                "docker run --rm --name bkg-wf-oidc "
                f"-e WF_SECRET_KEY='{SECRET}' "
                "-e WF_CORS_ALLOW_ORIGINS=http://127.0.0.1:18088 "
                "-e WF_OIDC_ISSUER_URL=http://127.0.0.1:9 "
                "-e WF_OIDC_CLIENT_ID=bakeoff-test "
                "-e WF_OIDC_REDIRECT_URL=http://127.0.0.1:18088/api/v1/auth/oidc/callback "
                "-e WF_OIDC_ALLOWED_EMAILS=test@example.invalid "
                f"{IMG} 2>&1"
            )
            assert rc != 0, f"booted with an unreachable OIDC issuer:\n{out}"
            assert "oidc" in out.lower(), out

        with subtest("🚨 an EMPTY OIDC allowlist refuses to boot (fail-closed)"):
            # No WF_OIDC_ALLOWED_* and no WF_OIDC_ALLOW_ANY: on a shared IdP
            # that combination would admit every authenticated account, so
            # the server panics in from_env — before discovery, hence no
            # allowlist env here and a dead issuer never reached.
            rc, out = services_vm.execute(
                "docker run --rm --name bkg-wf-allowany "
                f"-e WF_SECRET_KEY='{SECRET}' "
                "-e WF_CORS_ALLOW_ORIGINS=http://127.0.0.1:18088 "
                "-e WF_OIDC_ISSUER_URL=http://127.0.0.1:9 "
                "-e WF_OIDC_CLIENT_ID=bakeoff-test "
                "-e WF_OIDC_REDIRECT_URL=http://127.0.0.1:18088/api/v1/auth/oidc/callback "
                f"{IMG} 2>&1"
            )
            assert rc != 0, f"booted with OIDC open to every IdP account:\n{out}"
            assert "allow" in out.lower(), out

        with subtest("🚨 no secrets, no server — the finding-#11 race is loud"):
            # The property, pinned: a deploy that races the first decrypt
            # panics on the missing WF_SECRET_KEY and crash-loops in plain
            # sight. Contrast tandoor, where the same race silently runs on
            # an ephemeral SQLite file.
            rc, out = services_vm.execute(
                f"docker run --rm --name bkg-wf-nokey {IMG} 2>&1"
            )
            assert rc != 0, f"started with no WF_SECRET_KEY:\n{out}"
            assert "WF_SECRET_KEY" in out, out

        with subtest("🚨 10309 is unreachable from another machine"):
            ip = services_vm.succeed(
                "ip -4 -o addr show eth1 | awk '{print $4}' | cut -d/ -f1"
            ).strip()
            outsider.wait_for_unit("network.target")
            outsider.fail(
                f"curl -s --max-time 10 http://{ip}:10309/api/v1/healthz >/dev/null"
            )
            outsider.succeed(f"ping -c1 -W5 {ip} >/dev/null")

        with subtest("still healthy after the controls (nothing leaked into the stack)"):
            services_vm.succeed(
                "test \"$(docker inspect -f '{{.State.Health.Status}}' "
                "wealthfolio)\" = healthy"
            )
    except Exception:
        dump_diag()
        raise
  '';
}
