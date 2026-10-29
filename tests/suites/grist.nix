# Grist suite — hand-written because mk-stack-suite cannot boot it: Grist runs
# OIDC discovery before it listens and EXITS when the issuer does not answer,
# so on an offline VM the generic harness would watch a restart loop. Here a
# stub issuer stands in for Authentik: a second container on the project
# network, aliased auth.idanreed.com, serving the discovery document over TLS
# with a test CA that only the grist container is told to trust. A test-only
# compose override adds those two things and nothing else; every production
# value — the issuer URL, client id, sandbox, access flags — is the real one.
#
# Genuinely under test:
#   - 🚨 **Boots with OIDC configured and comes up healthy**, discovery
#     included — and the login it hands out is Authentik's authorize endpoint
#     with client_id `grist` and the redirect URI grist-oidc.yaml registers
#     (strict matching: a drift is a login-time failure).
#   - 🚨 **Formulas evaluate inside gVisor at default docker privileges.**
#     The image default is UNSANDBOXED; the boot-time runsc check passing,
#     the admin sandboxing probe reporting gvisor functional AND effective,
#     and a real formula computing through it are the three legs.
#   - **Anonymous access refused** (GRIST_FORCE_LOGIN), the env's built OIDC
#     secret present, and the boot key working as the only non-Authentik
#     login — the right key in, a wrong key 401.
#   - **idan owns the `home` site from boot** (created for GRIST_ADMIN_EMAIL).
#   - **backup-prepare.sh's Grist leg**: home.sqlite3 and the document dumped
#     as readable SQLite, and a dump whose document is gone removed.
#   - **10101 unreachable from another machine.**
#
# Documented gaps:
#   - **No real Authentik**: the token exchange, userinfo and the OIDC user
#     landing on the `home` site need a browser and the VPS. First deploy:
#     log in once and confirm `home` is listed as yours.
#   - **Through Caddy**: the vhost and the document websocket's Origin check
#     are not exercised here.

{
  pkgs,
  lib,
  images,
  profiles,
  sopsModule,
  ...
}:

let
  gristImage = images."gristlabs_grist-oss_1_7_21";
  stackImages = [ gristImage ];

  seedSrv = pkgs.runCommand "srv-seed-grist" { } ''
    mkdir -p $out/stacks/grist
    cp -r ${../../stacks/grist}/. $out/stacks/grist/
    chmod -R u+w $out/stacks/grist
    # A locally-decrypted plaintext .env is gitignored but would still be
    # captured by cp -r into the world-readable store.
    rm -f $out/stacks/grist/.env
    rm -f $out/stacks/grist/secrets.example.env $out/stacks/grist/secrets.sops.json
    ln -s /run/stack-env/grist.env $out/stacks/grist/.env
  '';

  # A throwaway CA and a leaf for auth.idanreed.com, minted at build time.
  stubCerts = pkgs.runCommand "grist-issuer-stub-certs" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir $out
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=grist-suite-ca" \
      -keyout ca.key -out $out/ca.pem
    openssl req -newkey rsa:2048 -nodes -subj "/CN=auth.idanreed.com" \
      -keyout $out/key.pem -out leaf.csr
    printf 'subjectAltName=DNS:auth.idanreed.com\n' > ext.cnf
    openssl x509 -req -in leaf.csr -CA $out/ca.pem -CAkey ca.key -CAcreateserial \
      -days 3650 -extfile ext.cnf -out $out/cert.pem
  '';

  # Authentik's discovery document for the `grist` application, trimmed to
  # what openid-client and Grist read. end_session_endpoint is required:
  # without one Grist refuses to start.
  issuerJs = pkgs.writeText "issuer.js" ''
    const https = require("https");
    const fs = require("fs");
    const base = "https://auth.idanreed.com/application/o";
    const meta = {
      issuer: base + "/grist/",
      authorization_endpoint: base + "/authorize/",
      token_endpoint: base + "/token/",
      userinfo_endpoint: base + "/userinfo/",
      end_session_endpoint: base + "/grist/end-session/",
      jwks_uri: base + "/grist/jwks/",
      response_types_supported: ["code"],
      subject_types_supported: ["public"],
      id_token_signing_alg_values_supported: ["RS256"],
      code_challenge_methods_supported: ["S256"],
    };
    https.createServer({
      key: fs.readFileSync("/stub/key.pem"),
      cert: fs.readFileSync("/stub/cert.pem"),
    }, (req, res) => {
      if (req.url === "/application/o/grist/.well-known/openid-configuration") {
        res.writeHead(200, { "content-type": "application/json" });
        res.end(JSON.stringify(meta));
      } else {
        res.writeHead(404);
        res.end();
      }
    }).listen(443);
  '';

  # The production compose plus the stub, merged by `docker compose -f a -f b`.
  overrideYaml = pkgs.writeText "grist-test-override.yaml" ''
    services:
      grist:
        environment:
          - NODE_EXTRA_CA_CERTS=/stub/ca.pem
        volumes:
          - /etc/grist-test:/stub:ro
        depends_on:
          grist-issuer-stub:
            condition: service_healthy
      grist-issuer-stub:
        image: ${gristImage.composeRef}
        container_name: grist_issuer_stub
        entrypoint: ["node", "/stub/issuer.js"]
        volumes:
          - /etc/grist-test:/stub:ro
        networks:
          default:
            aliases:
              - auth.idanreed.com
        healthcheck:
          test: ["CMD", "curl", "-fsS", "-o", "/dev/null", "--cacert", "/stub/ca.pem",
                 "--resolve", "auth.idanreed.com:443:127.0.0.1",
                 "https://auth.idanreed.com/application/o/grist/.well-known/openid-configuration"]
          interval: 2s
          timeout: 5s
          retries: 30
  '';

  stackMntRoots = [ "/mnt/fast/grist" ];
  stackDirRules = (import ../../nixos/stack-dirs.nix).systemd.tmpfiles.rules;
  rulePath = r: lib.elemAt (lib.splitString " " r) 1;
  covers = dir: p: p == dir || lib.hasPrefix (dir + "/") p;
  missingRoots = lib.filter (root: !(lib.any (r: rulePath r == root) stackDirRules)) stackMntRoots;
  mntRules =
    if missingRoots == [ ] then
      lib.filter (r: lib.any (covers (rulePath r)) stackMntRoots) stackDirRules
    else
      throw (
        "grist suite: nixos/stack-dirs.nix has no rule for "
        + lib.concatStringsSep ", " missingRoots
        + " — add the STACK_NOTES/DIR_NOTES entries and re-run nixos/generate-stack-dirs.sh"
      );
in
pkgs.testers.runNixOSTest {
  name = "grist";

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
            diskMB = 8192;
          })
          (profiles.loadImages {
            inherit pkgs;
            images = stackImages;
            beforeUnits = [ "multi-user.target" ];
          })
        ];

        systemd.services.bootstrap-komodo.wantedBy = lib.mkForce [ ];
        # Komodo's sync bootstrap Requires the masked unit and would pull it
        # back in; Forgejo runs from the host too, and only the forgejo and
        # gitops suites load its image.
        systemd.services.komodo-sync-bootstrap.wantedBy = lib.mkForce [ ];
        systemd.services.forgejo.wantedBy = lib.mkForce [ ];

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

        # Copies, not store symlinks: a bind mount of /etc/grist-test must
        # hold real files inside the container.
        environment.etc = {
          "grist-test/issuer.js" = {
            source = issuerJs;
            mode = "0444";
          };
          "grist-test/override.yaml" = {
            source = overrideYaml;
            mode = "0444";
          };
          "grist-test/ca.pem" = {
            source = "${stubCerts}/ca.pem";
            mode = "0444";
          };
          "grist-test/cert.pem" = {
            source = "${stubCerts}/cert.pem";
            mode = "0444";
          };
          "grist-test/key.pem" = {
            source = "${stubCerts}/key.pem";
            mode = "0400";
          };
        };

        systemd.services.seed-srv = {
          description = "Seed /srv with the grist stack (test only)";
          after = [ "srv.mount" ];
          requires = [ "srv.mount" ];
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
          sqlite
        ];
      };

    # curl EXPLICITLY: the outsider only ever runs it inside .fail(), and a
    # node without curl makes that negative pass vacuously.
    outsider =
      { pkgs, ... }:
      {
        environment.systemPackages = [ pkgs.curl ];
      };
  };

  testScript = ''
    import json
    from urllib.parse import urlsplit, parse_qs

    G = ("docker compose -f /srv/stacks/grist/compose.yaml "
         "-f /etc/grist-test/override.yaml -p grist")
    BASE = "http://127.0.0.1:10101"
    HOST = "-H 'Host: grist.svc.idanreed.com'"
    BOOT_KEY = "test_grist_boot_key_not_secret"

    def dump_diag():
        for label, cmd in [
            ("compose ps", f"{G} ps -a"),
            ("grist logs", "docker logs grist 2>&1 | tail -80"),
            ("stub logs", "docker logs grist_issuer_stub 2>&1 | tail -20"),
            ("stack-env-publish journal",
             "journalctl -u stack-env-publish --no-pager -o cat | tail -20"),
            ("data dir", "ls -la /mnt/fast/grist /mnt/fast/grist/docs 2>&1 | head -20"),
        ]:
            print(f"--- {label} ---")
            print(services_vm.execute(cmd)[1])

    start_all()

    # 600s: the production NIC name (ens18) is absent here and its device job
    # times out at ~300s before multi-user settles.
    services_vm.wait_for_unit("multi-user.target", timeout=600)
    services_vm.wait_for_unit("stack-env-publish.service")
    services_vm.wait_for_unit("docker-network-homelab.service")
    services_vm.wait_for_unit("load-test-images.service")

    try:
        with subtest("the env renders root-only, the OIDC secret built from the shared file"):
            mode = services_vm.succeed("stat -c '%a %U' /run/stack-env/grist.env").strip()
            assert mode == "400 root", f"expected '400 root', got {mode!r}"
            services_vm.succeed(
                "grep -qx \"GRIST_OIDC_IDP_CLIENT_SECRET='test_grist_oidc_secret_not_secret'\" "
                "/run/stack-env/grist.env"
            )

        with subtest("🚨 boots healthy with OIDC discovery against the issuer stub"):
            services_vm.succeed(f"{G} up -d --wait --wait-timeout 300")
            services_vm.succeed("docker logs grist 2>&1 | grep -F 'OIDCConfig: initialized with issuer https://auth.idanreed.com/application/o/grist/' >/dev/null")

        with subtest("🚨 the boot-time gVisor check passed"):
            # run.sh exits before the server when runsc cannot run a trivial
            # command with the image's flags, so this line plus a healthy
            # container is the first leg.
            services_vm.succeed("docker logs grist 2>&1 | grep -F 'gvisor check ok' >/dev/null")

        with subtest("anonymous requests are refused (GRIST_FORCE_LOGIN)"):
            # The API answers an anonymous caller with what anonymous may see:
            # nothing. The proof is that `home` is absent and unreadable, and
            # that the default email does not log anyone in.
            out = services_vm.succeed(
                f"curl -s -w '\\n%{{http_code}}' --max-time 10 {HOST} {BASE}/api/orgs"
            ).strip()
            body, _, code = out.rpartition("\n")
            print(f"anonymous /api/orgs: {code} {body}")
            assert code in ("200", "401", "403"), f"anonymous /api/orgs answered {code}"
            if code == "200":
                assert not [o for o in json.loads(body) if o.get("domain") == "home"], body
            code = services_vm.succeed(
                f"curl -s -o /dev/null -w '%{{http_code}}' --max-time 10 {HOST} {BASE}/api/orgs/home"
            ).strip()
            assert code in ("401", "403", "404"), f"anonymous /api/orgs/home answered {code}"
            code = services_vm.succeed(
                f"curl -s -o /dev/null -w '%{{http_code}}' --max-time 10 {HOST} {BASE}/"
            ).strip()
            assert code in ("302", "303"), f"anonymous / answered {code}, expected a redirect to login"

        with subtest("🚨 the login redirect is Authentik's, with the blueprint's exact redirect URI"):
            loc = services_vm.succeed(
                f"curl -s -o /dev/null -w '%{{redirect_url}}' --max-time 10 {HOST} {BASE}/login"
            ).strip()
            u = urlsplit(loc)
            q = parse_qs(u.query)
            assert (u.scheme, u.netloc, u.path) == ("https", "auth.idanreed.com", "/application/o/authorize/"), loc
            assert q.get("client_id") == ["grist"], q
            assert q.get("redirect_uri") == ["https://grist.svc.idanreed.com/oauth2/callback"], q
            assert q.get("response_type") == ["code"], q
            assert set(q["scope"][0].split()) >= {"openid", "email", "profile"}, q
            # PKCE and STATE, Grist's default protections.
            assert q.get("code_challenge_method") == ["S256"] and q.get("state"), q

        with subtest("a wrong boot key is refused"):
            code = services_vm.succeed(
                "curl -s -o /dev/null -w '%{http_code}' --max-time 10 "
                "-X POST -H 'Content-Type: application/json' "
                "-d '{\"bootKey\":\"wrong\",\"adminEmail\":\"idan@idanreed.com\"}' "
                f"{HOST} {BASE}/boot/login"
            ).strip()
            assert code == "401", f"wrong boot key answered {code}"

        with subtest("the boot key logs in as the install admin (fixture value survived the render)"):
            services_vm.succeed(
                "curl -fsS -D /tmp/g-headers -o /dev/null --max-time 10 "
                "-X POST -H 'Content-Type: application/json' "
                "-d '{\"bootKey\":\"" + BOOT_KEY + "\",\"adminEmail\":\"idan@idanreed.com\"}' "
                f"{HOST} {BASE}/boot/login"
            )
            # Read the cookie out of the headers: curl's jar would refuse to
            # replay a Secure cookie over plain http.
            cookie = services_vm.succeed(
                "sed -n 's/^[Ss]et-[Cc]ookie: *\\(grist_core[^=]*=[^;]*\\).*/\\1/p' /tmp/g-headers | tail -1"
            ).strip()
            assert cookie.startswith("grist_core"), f"no session cookie in the boot login response: {cookie!r}"
            AUTH = f"{HOST} -H 'Cookie: {cookie}'"

        with subtest("idan owns the `home` site from the first boot"):
            orgs = json.loads(services_vm.succeed(f"curl -fsS --max-time 10 {AUTH} {BASE}/api/orgs"))
            home = [o for o in orgs if o.get("domain") == "home"]
            assert home and home[0].get("access") == "owners", f"orgs: {orgs}"

        with subtest("🚨 the sandboxing probe: gVisor, functional and effective"):
            probe = json.loads(services_vm.succeed(
                f"curl -fsS --max-time 60 {AUTH} {BASE}/api/probes/sandboxing"
            ))
            d = probe.get("details") or {}
            assert probe.get("status") == "success", probe
            assert d.get("flavor") == "gvisor" and d.get("functional") and d.get("effective"), probe
            auth = json.loads(services_vm.succeed(
                f"curl -fsS --max-time 30 {AUTH} {BASE}/api/probes/authentication"
            ))
            assert auth.get("status") == "success", auth

        with subtest("🚨 a formula computes through the sandbox, in a document on the bind mount"):
            wss = json.loads(services_vm.succeed(
                f"curl -fsS --max-time 10 {AUTH} {BASE}/api/orgs/home/workspaces"
            ))
            if wss:
                ws = wss[0]["id"]
            else:
                ws = json.loads(services_vm.succeed(
                    f"curl -fsS --max-time 10 {AUTH} -X POST -H 'Content-Type: application/json' "
                    f"-d '{{\"name\":\"suite\"}}' {BASE}/api/orgs/home/workspaces"
                ))
            doc = json.loads(services_vm.succeed(
                f"curl -fsS --max-time 30 {AUTH} -X POST -H 'Content-Type: application/json' "
                f"-d '{{\"name\":\"suite-doc\"}}' {BASE}/api/workspaces/{ws}/docs"
            ))
            assert isinstance(doc, str) and doc, f"doc create returned {doc!r}"
            tables = {"tables": [{"id": "Suite", "columns": [
                {"id": "A", "fields": {"label": "A", "type": "Numeric"}},
                {"id": "B", "fields": {"label": "B", "isFormula": True, "formula": "$A * 2"}},
            ]}]}
            services_vm.succeed(
                f"curl -fsS --max-time 60 {AUTH} -X POST -H 'Content-Type: application/json' "
                f"-d '{json.dumps(tables)}' {BASE}/api/docs/{doc}/tables"
            )
            services_vm.succeed(
                f"curl -fsS --max-time 60 {AUTH} -X POST -H 'Content-Type: application/json' "
                "-d '{\"records\":[{\"fields\":{\"A\":21}}]}' "
                f"{BASE}/api/docs/{doc}/tables/Suite/records"
            )
            recs = json.loads(services_vm.succeed(
                f"curl -fsS --max-time 60 {AUTH} {BASE}/api/docs/{doc}/tables/Suite/records"
            ))["records"]
            assert recs and recs[0]["fields"].get("B") == 42, f"formula result: {recs}"
            services_vm.succeed(f"test -s /mnt/fast/grist/docs/{doc}.grist")
            services_vm.succeed("test -s /mnt/fast/grist/home.sqlite3")
            owner = services_vm.succeed("stat -c %u /mnt/fast/grist").strip()
            assert owner == "1001", f"/mnt/fast/grist is owned by {owner}, expected 1001"

        with subtest("backup-prepare.sh dumps the home DB and every document, and drops orphans"):
            services_vm.succeed(
                "install -d -m 0700 /mnt/fast/_dumps/grist-docs && "
                "echo stale > /mnt/fast/_dumps/grist-docs/ghostdoc.sqlite"
            )
            # The run as a whole fails here (no VPS to pull from); only the
            # local dumps are under test.
            services_vm.execute("systemctl start backup-prepare.service")
            print(services_vm.execute(
                "journalctl -u backup-prepare --no-pager -o cat | grep -i grist"
            )[1])
            services_vm.succeed(
                "sqlite3 /mnt/fast/_dumps/grist.sqlite 'select count(*) from orgs' | grep -qvx 0"
            )
            services_vm.succeed(
                f"sqlite3 /mnt/fast/_dumps/grist-docs/{doc}.sqlite 'select count(*) from Suite' "
                "| grep -qx 1"
            )
            services_vm.fail("test -e /mnt/fast/_dumps/grist-docs/ghostdoc.sqlite")

        with subtest("🚨 10101 is unreachable from another machine"):
            ip = services_vm.succeed(
                "ip -4 -o addr show eth1 | awk '{print $4}' | cut -d/ -f1"
            ).strip()
            outsider.wait_for_unit("network.target")
            outsider.succeed(f"ping -c1 -W5 {ip} >/dev/null")
            outsider.fail(f"curl -s --max-time 10 http://{ip}:10101/ >/dev/null")

        with subtest("still healthy at the end"):
            services_vm.succeed(
                "test \"$(docker inspect -f '{{.State.Health.Status}}' grist)\" = healthy"
            )
    except Exception:
        dump_diag()
        raise
  '';
}
