# Forward auth: the bentopdf pilot, end to end minus the browser.
#
# Same composition as tailnet.nix — the real VPS (caddy + headscale + the REAL
# authentik), the real services VM with its stacks, Pebble, and a tailnet
# client — because forward auth is exactly a cross-host seam: the services
# VM's Caddy calls the VPS's embedded outpost on every request to a protected
# route, and both ends have to agree on the external host.
#
# Genuinely under test:
#   - blueprints/custom/forward-auth.yaml applying against the pinned
#     authentik: proxy provider (forward_single, the right external_host),
#     application, and assignment to the EMBEDDED outpost — the delivery
#     contract for the whole feature
#   - the blueprint's outpost identifier ("authentik Embedded Outpost")
#     matching the name authentik actually gives its embedded outpost, so the
#     entry updates it rather than minting a second, unconnected outpost
#   - Caddy's (protected) snippet + the bentopdf `import protected` pilot:
#     an unauthenticated tailnet request never reaches the app and is
#     redirected toward the login machinery instead
#   - the forward_auth upstream (the outpost's /auth/caddy behind the VPS
#     Caddy, dialled over the tailnet) existing and answering
#   - the trusted_proxies contract from modules/caddy.nix, BOTH WAYS: a
#     tailnet source's X-Forwarded-Host reaches the outpost, an off-tailnet
#     source's spoofed one is stripped (404, not a login flow)
#   - NO-LOCKOUT: the import did not leak onto other handles — ntfy still
#     serves without auth
#
# CANNOT COVER — the authenticated browser flow. Completing a login needs a
# real browser (authentik's flow executor is a JS app; TOTP enrolment is
# mandatory per headscale-oidc.yaml's MFA override), and the harness has
# none. So the suite proves the unauthenticated half at the wire and the
# authenticated half at the API level: the provider/application/outpost
# objects exist with the right external_host, which is everything the
# blueprint can deliver. The first real login through a browser remains a
# manual checkbox after deploy.
#
# Suite-local overrides, beyond what ../lib/profiles.nix documents:
#   - the DNS-01 tls block -> tls internal (same as services-vm/tailnet, and
#     the substitution asserts it still matches exactly once)
#   - a tls_trust_pool line added to the (protected) snippet's transport
#     block so the caddy CONTAINER trusts Pebble's per-run issuing root for
#     the forward_auth hop (host trust stores do not reach into containers),
#     plus a compose overlay mounting /var/lib/test-ca. Coverage lost:
#     nothing about the hop itself — TLS still happens and is verified
#     against tls_server_name, just under the test CA.

{
  pkgs,
  lib,
  images,
  profiles,
  sopsModule,
  acmeServerModule,
  ...
}:

let
  headscaleHost = "headscale.idanreed.com";
  authHost = "auth.idanreed.com";

  stacks = [
    "ntfy"
    "util"
    "caddy"
  ];

  stackImages = [
    images."ghcr_io_moghtech_komodo-core_2_1_0"
    images."ghcr_io_moghtech_komodo-periphery_2_1_0"
    images."ghcr_io_ferretdb_ferretdb_2_7_0"
    images."ghcr_io_ferretdb_postgres-documentdb_17-0_107_0-ferretdb-2_7_0"
    images."binwiederhier_ntfy_v2_11_0"
    images."ghcr_io_alam00000_bentopdf_1_16_1"
    images."ghcr_io_civilblur_mazanoke_v1_1_5"
    # The util stack is `up`'d whole, so ALL FOUR of its services need their
    # images preloaded — a missing one surfaces as a pull attempt, not as
    # anything forward-auth-related.
    images."glanceapp_glance_v0_8_5"
    images."ghcr_io_sharevb_it-tools_2026_7_11"
    images."ghcr_io_idanreed_caddy-cloudflare_2_11_2"
  ];

  # Two substitutions, each asserted to match exactly once so any other edit
  # to the Caddyfile is still tested verbatim:
  #   1. DNS-01 -> tls internal (Cloudflare is unreachable from the sandbox).
  #   2. A tls_trust_pool added to the (protected) snippet's existing
  #      transport block, so the caddy container verifies the VPS's
  #      Pebble-issued certificate against the per-run root instead of
  #      failing the hop with an unknown CA (which would surface as a 502 on
  #      every protected route and prove nothing about forward auth).
  testCaddyfile =
    pkgs.runCommand "Caddyfile.test" { nativeBuildInputs = [ pkgs.python3 ]; }
      ''
        python3 - <<'PY'
        import os, re, sys
        src = open("${../../stacks/caddy/Caddyfile}").read()

        pattern = re.compile(r"\n\ttls \{\n\t\tdns cloudflare \{env\.CLOUDFLARE_API_TOKEN\}\n\t\}\n")
        out, n = pattern.subn("\n\ttls internal\n", src)
        if n != 1:
            print(f"expected one DNS-01 tls block, found {n}", file=sys.stderr)
            sys.exit(1)

        fa = re.compile(
            r"(\n\t\ttransport http \{\n"
            r"\t\t\ttls_server_name auth\.idanreed\.com\n)")
        out, n = fa.subn(
            r"\1\t\t\ttls_trust_pool file /var/lib/test-ca/bundle.pem\n",
            out,
        )
        if n != 1:
            print(f"expected one (protected) transport block, found {n}.",
                  file=sys.stderr)
            print("The trust-pool injection is stale — update "
                  "tests/suites/forward-auth.nix.", file=sys.stderr)
            sys.exit(1)

        open(os.environ["out"], "w").write(out)
        PY
      '';

  # Compose overlay for the trust-pool file above: the production compose
  # mounts only ./Caddyfile, and /var/lib/test-ca is populated at runtime by
  # profiles.pebbleTrust. Merged via a second -f; compose appends volume
  # lists, so the production mounts are untouched.
  caddyTestOverride = pkgs.writeText "caddy-test-override.yaml" ''
    services:
      caddy:
        volumes:
          - /var/lib/test-ca:/var/lib/test-ca:ro
  '';

  seedSrv = pkgs.runCommand "srv-seed" { } ''
    mkdir -p $out/komodo $out/stacks
    cp ${../../komodo/compose.yaml} $out/komodo/compose.yaml
    cp ${../fixtures/komodo.sops.env} $out/komodo/.sops.env
    ${lib.concatMapStringsSep "\n" (s: ''
      mkdir -p $out/stacks/${s}
      cp -r ${../../stacks + "/${s}"}/. $out/stacks/${s}/
      chmod -R u+w $out/stacks/${s}
      rm -f $out/stacks/${s}/.sops.env.example
      ${lib.optionalString (builtins.pathExists (../fixtures + "/${s}.sops.env")) ''
        cp ${../fixtures + "/${s}.sops.env"} $out/stacks/${s}/.sops.env
      ''}
    '') stacks}
    cp ${testCaddyfile} $out/stacks/caddy/Caddyfile
  '';
in
pkgs.testers.runNixOSTest {
  name = "forward-auth";

  # Two full hosts + Authentik + three stacks, and wait_until_succeeds
  # timeouts count ITERATIONS (command duration + 1s each), so the worst
  # case here overruns the 3600s default and reds as a driver kill blamed
  # on the wrong subsystem.
  globalTimeout = 7200;

  nodes = {
    vps =
      { nodes, ... }:
      {
        imports = [
          sopsModule
          ../../headscale-vps/configuration.nix
          ../../headscale-vps/modules/caddy.nix
          ../../headscale-vps/modules/headscale.nix
          # The REAL authentik: the blueprint under test only means anything
          # applied against the pinned image by the real worker.
          ../../headscale-vps/modules/authentik.nix

          profiles.noBootloader
          profiles.noDhcp
          profiles.manualTailscaleAutoconnect
          (profiles.pebbleTrust {
            caDomain = nodes.acme.test-support.acme.caDomain;
            caCert = nodes.acme.test-support.acme.caCert;
          })
          (profiles.sopsFixture ../fixtures/vps.sops.yaml)
          (profiles.sized {
            memoryMB = 6144;
            diskMB = 16384;
          })
          (profiles.loadImages {
            inherit pkgs;
            images = [
              images."ghcr_io_goauthentik_server_2026_5_6"
              images."postgres_16_13-alpine"
              images."redis_7_4-alpine"
            ];
            beforeUnits = [ "authentik.service" ];
          })
        ];

        services.caddy.globalConfig = lib.mkAfter ''
          acme_ca https://${nodes.acme.test-support.acme.caDomain}/dir
        '';
        security.pki.certificateFiles = [ nodes.acme.test-support.acme.caCert ];
        networking.hosts."127.0.0.1" = [
          headscaleHost
          authHost
        ];

        environment.systemPackages = [ pkgs.headscale ];
      };

    services =
      { nodes, pkgs, ... }:
      {
        imports = [
          sopsModule
          ../../nixos/configuration.nix

          profiles.noBootloader
          profiles.noDhcp
          profiles.manualTailscaleAutoconnect
          (profiles.pebbleTrust {
            caDomain = nodes.acme.test-support.acme.caDomain;
            caCert = nodes.acme.test-support.acme.caCert;
          })
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

        security.pki.certificateFiles = [ nodes.acme.test-support.acme.caCert ];
        # auth.idanreed.com must resolve on this HOST: the caddy container is
        # network_mode host, and docker builds a host-networked container's
        # /etc/hosts from the host's — this entry is what the forward_auth hop
        # rides. In production it is a public A record to the VPS.
        networking.hosts.${nodes.vps.networking.primaryIPAddress} = [
          headscaleHost
          authHost
        ];

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
          "d /srv/komodo 0755 root root -"
          "d /srv/stacks 0755 1000 1000 -"
          "d /var/lib/sops-nix 0700 root root -"
          "d /mnt/fast/caddy 0755 root root -"
          "d /mnt/fast/ntfy 0755 root root -"
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
      };

    acme =
      { nodes, ... }:
      {
        imports = [ acmeServerModule ];
        networking.hosts.${nodes.vps.networking.primaryIPAddress} = [
          headscaleHost
          authHost
        ];
      };

    # Stands in for a laptop on the tailnet — the only vantage point that can
    # reach the services VM's Caddy, and therefore the only place the pilot's
    # redirect can honestly be observed from.
    client =
      { nodes, pkgs, ... }:
      {
        imports = [
          (profiles.pebbleTrust {
            caDomain = nodes.acme.test-support.acme.caDomain;
            caCert = nodes.acme.test-support.acme.caCert;
          })
        ];
        services.tailscale.enable = true;
        security.pki.certificateFiles = [ nodes.acme.test-support.acme.caCert ];
        networking.hosts.${nodes.vps.networking.primaryIPAddress} = [
          headscaleHost
          authHost
        ];
        environment.systemPackages = [ pkgs.jq ];
      };
  };

  testScript =
    { nodes, ... }:
    ''
      import json

      # Pebble's per-run issuing root, fetched at runtime by
      # profiles.pebbleTrust — used for every assertion against the VPS's
      # public names. The *.svc.idanreed.com requests below use -k instead:
      # the services VM's Caddy runs `tls internal` here (the test
      # substitution for DNS-01), so its CA is per-run Caddy-generated and
      # verifying it proves nothing about production.
      CA = "--cacert /var/lib/test-ca/bundle.pem"

      # The bootstrap token from ../fixtures/vps.sops.yaml — same API-auth
      # pattern as authentik.nix.
      TOKEN = "test0bootstrap0token0deadbeef0deadbeef0deadbeef"
      API = "http://127.0.0.1:9000/api/v3"
      CURL = f"curl -sf --max-time 10 -H 'Authorization: Bearer {TOKEN}'"
      CURL_RAW = f"curl -s --max-time 10 -H 'Authorization: Bearer {TOKEN}'"

      EXTERNAL_HOST = "https://bentopdf.svc.idanreed.com"
      EMBEDDED_MANAGED = "goauthentik.io/outposts/embedded"


      def authentik_diag():
          # Blueprint errors appear ONLY in the worker's logs — the API just
          # never grows the objects — so always dump them on the way out.
          for label, cmd in [
              ("docker ps", "docker ps -a"),
              ("authentik.service", "journalctl -u authentik --no-pager | tail -60"),
              ("worker logs", "docker logs authentik_worker 2>&1 | tail -100"),
              ("server logs", "docker logs authentik_server 2>&1 | tail -40"),
          ]:
              print(f"=== {label} ===")
              print(headscale_vps.execute(cmd)[1])


      def caddy_diag():
          for label, cmd in [
              ("caddy container", "docker logs caddy 2>&1 | tail -60"),
              ("caddy Caddyfile", "docker exec caddy cat /etc/caddy/Caddyfile"),
              ("host /etc/hosts", "cat /etc/hosts"),
              ("container hosts", "docker exec caddy cat /etc/hosts"),
          ]:
              print(f"=== {label} ===")
              print(services_vm.execute(cmd)[1])


      start_all()
      acme.wait_for_unit("pebble.service")

      # -----------------------------------------------------------------------
      # Control plane + tailnet (the transport the pilot rides on)
      # -----------------------------------------------------------------------
      headscale_vps.wait_for_unit("headscale.service")
      headscale_vps.wait_for_unit("caddy.service")
      headscale_vps.wait_until_succeeds(
          f"curl -sf {CA} --max-time 5 https://${headscaleHost}/health", timeout=180
      )

      headscale_vps.succeed("headscale users create idan")
      users = json.loads(headscale_vps.succeed("headscale users list -o json"))
      uid = str(users[0]["id"])

      def authkey():
          return headscale_vps.succeed(
              f"headscale preauthkeys create --user {uid} --reusable --expiration 24h"
          ).strip().splitlines()[-1]

      # ALL THREE join. The VPS's own join is not a nicety here: the
      # (protected) snippet dials the VPS by its MagicDNS node name so the
      # forward-auth hop's source address is a tailnet one (the only sources
      # the VPS Caddy's trusted_proxies keeps X-Forwarded-Host from), and
      # that name only exists once the VPS is a node.
      with subtest("the services VM, the VPS and a client join the tailnet"):
          def join(machine, secret_path):
              key = authkey()
              machine.succeed(f"install -m 0400 /dev/null {secret_path}.new")
              machine.succeed(f"printf '%s' '{key}' > {secret_path}.new")
              machine.succeed(f"mv {secret_path}.new {secret_path}")
              machine.succeed("systemctl restart tailscale-autoconnect.service")
              machine.wait_until_succeeds(
                  "tailscale status --json | jq -e '.BackendState == \"Running\"'",
                  timeout=180,
              )
              return machine.succeed("tailscale ip -4").strip()

          services_vm.wait_for_unit("bootstrap-komodo.service")
          svc_ip = join(services_vm,
                        "${nodes.services.sops.secrets.TAILSCALE_AUTH_KEY.path}")
          assert svc_ip.startswith("100."), f"services-vm got {svc_ip!r}"

          vps_ip = join(headscale_vps,
                        "${nodes.vps.sops.secrets.TAILSCALE_AUTH_KEY.path}")
          assert vps_ip.startswith("100."), f"vps got {vps_ip!r}"

          client.wait_for_unit("tailscaled.service")
          client.succeed(
              f"tailscale up --login-server https://${headscaleHost} "
              f"--auth-key {authkey()} --hostname client"
          )
          client.wait_until_succeeds(
              "tailscale status --json | jq -e '.BackendState == \"Running\"'",
              timeout=120,
          )
          client.wait_until_succeeds(f"ping -c 3 -W 5 {svc_ip}", timeout=90)

      with subtest("MagicDNS resolves the VPS from the services VM"):
          # The snippet's forward_auth target. The caddy CONTAINER inherits
          # the host's resolv.conf (host networking), so host-level
          # resolution is what it will see — but only if the stack comes up
          # AFTER the join, which is the production ordering too (the caddy
          # stack binds TAILNET_IP, unknown before the join).
          services_vm.wait_until_succeeds(
              "getent hosts headscale-vps.tailnet.idanreed.com", timeout=60
          )

      # -----------------------------------------------------------------------
      # Stacks up: caddy (with the pilot Caddyfile), the pilot app, ntfy
      # -----------------------------------------------------------------------
      with subtest("caddy, util and ntfy come up on the services VM"):
          # TAILNET_IP is only known post-join, same dance as tailnet.nix.
          services_vm.succeed(
              f"sed -i 's|^TAILNET_IP=.*|TAILNET_IP={svc_ip}|' /srv/stacks/caddy/.env"
          )
          # Second -f: the test-only overlay mounting the runtime CA bundle
          # for the (protected) snippet's injected trust pool.
          services_vm.succeed(
              "docker compose -f /srv/stacks/caddy/compose.yaml "
              "-f ${caddyTestOverride} -p caddy "
              "up -d --wait --wait-timeout 180"
          )
          services_vm.succeed(
              "docker compose -f /srv/stacks/util/compose.yaml -p util "
              "up -d --wait --wait-timeout 180"
          )
          services_vm.succeed(
              "docker compose -f /srv/stacks/ntfy/compose.yaml -p ntfy "
              "up -d --wait --wait-timeout 180"
          )
          services_vm.wait_for_open_port(443, addr=svc_ip)

          # Liveness controls on loopback: the redirect assertions below are
          # only meaningful against a live app — a dead bentopdf would make
          # "the app was never reached" vacuously true.
          services_vm.wait_until_succeeds(
              "curl -sf --max-time 5 http://127.0.0.1:10401/ -o /dev/null", timeout=120
          )
          services_vm.wait_until_succeeds(
              "curl -sf --max-time 5 http://127.0.0.1:10001/v1/health -o /dev/null",
              timeout=120,
          )

      # -----------------------------------------------------------------------
      # Authentik + the forward-auth blueprint (the delivery contract)
      # -----------------------------------------------------------------------
      with subtest("authentik.service reaches active"):
          # Not wait_for_unit: Restart=on-failure means a transient failed
          # state mid-retry would abort the wait. First start runs every DB
          # migration — be generous, and dump diagnostics rather than
          # grinding silently.
          try:
              headscale_vps.wait_until_succeeds(
                  "systemctl is-active --quiet authentik.service", timeout=900
              )
          except Exception:
              authentik_diag()
              raise

      with subtest("the embedded outpost carries the name the blueprint targets"):
          # forward-auth.yaml identifies the outpost as 'authentik Embedded
          # Outpost'. If the pinned authentik names it anything else, the
          # blueprint would CREATE a second outpost (or fail on missing
          # required fields) and the embedded one would never learn about the
          # provider — every protected route 404s. Pin the name here so an
          # image bump that renames it fails loudly.
          out = json.loads(headscale_vps.wait_until_succeeds(
              f"{CURL} '{API}/outposts/instances/'", timeout=300
          ))
          embedded = [o for o in out["results"] if o["managed"] == EMBEDDED_MANAGED]
          assert embedded, f"no embedded outpost at all: {out['results']!r}"
          name = embedded[0]["name"]
          assert name == "authentik Embedded Outpost", (
              f"embedded outpost is named {name!r} — update the identifier in "
              "blueprints/custom/forward-auth.yaml to match"
          )

      # Blueprints apply asynchronously AFTER the worker's healthcheck passes,
      # so poll — and on failure disambiguate never-DISCOVERED (instance list)
      # from discovered-but-failed-to-APPLY (worker logs), same as
      # authentik.nix.
      with subtest("the forward-auth blueprint has been applied"):
          for what, cmd in [
              # Select by exact name: the list endpoint's ?name= filter is
              # fuzzy-at-best (with the media providers present it returned
              # bazarr first), so .results[0] is whichever sorts first.
              ("proxy provider 'bentopdf' in forward_single mode",
               f"{CURL} '{API}/providers/proxy/?name=bentopdf' "
               "| jq -e '[.results[] | select(.name == \"bentopdf\")] "
               "| length == 1 and .[0].mode == \"forward_single\"'"),
              ("application with slug 'bentopdf'",
               f"{CURL} '{API}/core/applications/bentopdf/' "
               "| jq -e '.slug == \"bentopdf\"'"),
          ]:
              try:
                  headscale_vps.wait_until_succeeds(cmd, timeout=300)
              except Exception:
                  print(f"blueprint object never appeared: {what}")
                  for label, dcmd in [
                      ("api status, raw",
                       f"{CURL_RAW} -i '{API}/providers/proxy/?name=bentopdf' | head -30"),
                      ("blueprint instances",
                       f"{CURL} '{API}/managed/blueprints/' "
                       "| jq '.results[] | {name, path, status, last_applied}'"),
                      ("custom dir in worker",
                       "docker exec authentik_worker ls -la /blueprints/custom"),
                      ("worker log: forward-auth",
                       "docker logs authentik_worker 2>&1 "
                       "| grep -iE 'forward-auth|bentopdf|outpost|discover' | tail -30"),
                      ("worker errors",
                       "docker logs authentik_worker 2>&1 "
                       "| grep -iE '\"level\": \"(error|warning)\"|Traceback|exc_type' "
                       "| tail -40"),
                  ]:
                      print(f"=== {label} ===")
                      print(headscale_vps.execute(dcmd)[1])
                  authentik_diag()
                  raise

      with subtest("provider, application and outpost agree on the pilot"):
          # The delivery contract the browser flow would consume: the
          # provider's external_host is the exact public name Caddy protects,
          # the application points at that provider, and the EMBEDDED outpost
          # (not some fresh one) carries the assignment.
          providers = json.loads(headscale_vps.succeed(
              f"{CURL} '{API}/providers/proxy/?name=bentopdf'"
          ))
          # Exact-name selection, not results[0]: the ?name= filter does not
          # pin the order once the six media providers exist alongside.
          matches = [p for p in providers["results"] if p["name"] == "bentopdf"]
          assert len(matches) == 1, (
              f"expected exactly one provider named 'bentopdf', got "
              f"{[p['name'] for p in providers['results']]}"
          )
          prov = matches[0]
          pk = prov["pk"]
          assert prov["external_host"].rstrip("/") == EXTERNAL_HOST, (
              f"external_host is {prov['external_host']!r}, "
              f"expected {EXTERNAL_HOST!r} — the outpost matches the forwarded "
              "Host against this, so a mismatch is a 404 on every request"
          )

          app = json.loads(headscale_vps.succeed(
              f"{CURL} '{API}/core/applications/bentopdf/'"
          ))
          assert app["provider"] == pk, (
              f"application 'bentopdf' points at provider {app['provider']!r}, "
              f"expected {pk}"
          )

          # Outpost assignment is applied by the worker too — keep polling
          # rather than asserting a snapshot, with the same diag on the way out.
          try:
              headscale_vps.wait_until_succeeds(
                  f"{CURL} '{API}/outposts/instances/' "
                  f"| jq -e '.results[] "
                  f"| select(.managed == \"{EMBEDDED_MANAGED}\") "
                  f"| .providers | index({pk}) != null'",
                  timeout=300,
              )
          except Exception:
              print(headscale_vps.execute(
                  f"{CURL} '{API}/outposts/instances/' | jq .")[1])
              authentik_diag()
              raise

      # -----------------------------------------------------------------------
      # (a) Unauthenticated requests never reach the pilot app
      # -----------------------------------------------------------------------
      with subtest("an unauthenticated tailnet request to bentopdf is redirected"):
          # A runtime-derived marker from the live app, so 'the response is
          # not bentopdf' cannot rot into a stale-string comparison.
          app_marker = services_vm.succeed(
              "curl -s --max-time 5 http://127.0.0.1:10401/ "
              "| grep -io '<title>[^<]*' | head -1"
          ).strip()
          assert app_marker, "could not derive a content marker from the live app"

          # *.svc.idanreed.com is a public A record for the tailnet IP in
          # production; --resolve stands in for it per request.
          curl = (
              f"curl -sk --max-time 15 "
              f"--resolve bentopdf.svc.idanreed.com:443:{svc_ip} "
              "https://bentopdf.svc.idanreed.com/ "
              "-o /tmp/bento.body -D /tmp/bento.hdrs -w '%{http_code}'"
          )
          try:
              code = client.wait_until_succeeds(
                  # 30x now, not 200: retry while authentik's outpost config
                  # propagates, but a 200 (the app!) must fail the poll, so
                  # anchor on the redirect class.
                  f"c=$({curl}); echo $c; case $c in 3??) exit 0;; *) exit 1;; esac",
                  timeout=180,
              ).strip().splitlines()[-1]
          except Exception:
              print("last response:")
              print(client.execute("cat /tmp/bento.hdrs /tmp/bento.body")[1])
              caddy_diag()
              authentik_diag()
              raise

          hdrs = client.succeed("cat /tmp/bento.hdrs")
          body = client.succeed("cat /tmp/bento.body || true")
          locations = [l.split(":", 1)[1].strip() for l in hdrs.splitlines()
                       if l.lower().startswith("location:")]
          assert locations, f"redirect with no Location header:\n{hdrs}"
          loc = locations[0]

          # With authentik_host configured (forward-auth.yaml), the outpost's
          # handleAuthStart 302s straight to the authorize URL on
          # auth.idanreed.com, redirect_uri pointing back at bentopdf's
          # /outpost.goauthentik.io/callback. Older/other code paths bounce
          # via the on-host start URI first — the follow-up subtest covers
          # that shape. Either way it must be the login machinery, not the
          # app.
          assert ("/outpost.goauthentik.io/" in loc) or ("${authHost}" in loc), (
              f"redirected somewhere that is not the auth machinery: {loc!r}"
          )

          # And the body is the redirect stub, not the app.
          assert app_marker.lower() not in body.lower(), (
              f"unauthenticated response contains the app's own content "
              f"({app_marker!r}) — forward auth is not in front of it"
          )

      with subtest("the start URI itself also redirects into authentik, not the app"):
          # Second hop of the unauthenticated flow: following the Location
          # above must land the browser at auth.idanreed.com's flow, proving
          # the outpost knows this external_host end to end. Only run when the
          # first hop pointed at the on-host start URI.
          hdrs = client.succeed("cat /tmp/bento.hdrs")
          locations = [l.split(":", 1)[1].strip() for l in hdrs.splitlines()
                       if l.lower().startswith("location:")]
          loc = locations[0]
          if "${authHost}" in loc:
              print(f"first hop already at the IdP ({loc!r}); nothing to follow")
          else:
              path = loc.split("bentopdf.svc.idanreed.com", 1)[-1]
              out = client.succeed(
                  f"curl -sk --max-time 15 "
                  f"--resolve bentopdf.svc.idanreed.com:443:{svc_ip} "
                  f"'https://bentopdf.svc.idanreed.com{path}' "
                  "-o /dev/null -D - -w '%{http_code}'"
              )
              code = out.strip().splitlines()[-1]
              assert code.startswith("3"), (
                  f"start URI answered {code}, expected a redirect into the "
                  f"IdP:\n{out}"
              )
              locs2 = [l.split(":", 1)[1].strip() for l in out.splitlines()
                       if l.lower().startswith("location:")]
              assert locs2 and "${authHost}" in locs2[0], (
                  f"start URI redirected to {locs2!r}, expected ${authHost}"
              )

      # -----------------------------------------------------------------------
      # (b) The forward_auth upstream answers — from the tailnet
      # -----------------------------------------------------------------------
      with subtest("the outpost endpoint answers a tailnet forward-auth probe"):
          # The exact URL the (protected) snippet points at, with the
          # X-Forwarded-* headers caddy's forward_auth sends, dialled over
          # the TAILNET like the snippet does — the only sources whose
          # X-Forwarded-Host the VPS Caddy's trusted_proxies keeps. A
          # non-5xx, non-404 answer proves the upstream exists, the embedded
          # outpost is alive, and it knows the pilot host.
          #
          # POLLED on the http code, not on curl's exit: curl -s exits 0 for
          # any answered status, and the embedded outpost consumes the
          # provider assignment asynchronously (a refresh signal from the
          # API), so an answer right after apply can be a 404 that turns into
          # the real response seconds later.
          probe = (
              f"curl -s {CA} --max-time 10 -o /dev/null -w '%{{http_code}}' "
              "-H 'X-Forwarded-Host: bentopdf.svc.idanreed.com' "
              "-H 'X-Forwarded-Proto: https' -H 'X-Forwarded-Uri: /' "
              f"--resolve ${authHost}:443:{vps_ip} "
              "https://${authHost}/outpost.goauthentik.io/auth/caddy"
          )
          try:
              code = client.wait_until_succeeds(
                  f"c=$({probe}); echo $c; "
                  "case $c in 2??|3??|401|403) exit 0;; *) exit 1;; esac",
                  timeout=180,
              ).strip().splitlines()[-1]
          except Exception:
              print("last probe answer:")
              print(client.execute(f"{probe}; echo")[1])
              authentik_diag()
              raise
          # 2xx is forward_auth's "let the request through" — for an
          # UNAUTHENTICATED probe that would mean the gate is wide open.
          assert not code.startswith("2"), (
              f"outpost auth endpoint returned {code} to an unauthenticated "
              "probe — forward_auth would wave everything through"
          )

      with subtest("a spoofed X-Forwarded-Host from OFF the tailnet is stripped"):
          # The other half of the trusted_proxies contract: the same probe
          # arriving from a non-tailnet source (the client's VLAN address —
          # ${authHost} resolves to the VPS's LAN IP here, standing in for
          # the public route) must have its X-Forwarded-Host REPLACED by
          # Caddy, leaving the outpost nothing to match — 404, not a login
          # redirect. If this ever answers like the tailnet probe, anyone on
          # the internet can drive the outpost's auth flow for arbitrary
          # hosts with a spoofed header.
          code = client.succeed(
              f"curl -s {CA} --max-time 10 -o /dev/null -w '%{{http_code}}' "
              "-H 'X-Forwarded-Host: bentopdf.svc.idanreed.com' "
              "-H 'X-Forwarded-Proto: https' -H 'X-Forwarded-Uri: /' "
              "https://${authHost}/outpost.goauthentik.io/auth/caddy"
          ).strip()
          assert code == "404", (
              f"spoofed forward-auth probe from an untrusted source returned "
              f"{code}, expected 404 — trusted_proxies is not confining "
              "X-Forwarded-Host to the tailnet"
          )

      # -----------------------------------------------------------------------
      # (c) NO-LOCKOUT: the import did not leak onto other handles
      # -----------------------------------------------------------------------
      with subtest("ntfy still serves without auth"):
          # A 200 with the health body — not a redirect — from an
          # unprotected route proves `import protected` is scoped to the
          # bentopdf handle alone. This is the guard against the failure mode
          # where a snippet lands at site level and locks every service (ntfy
          # alerts included) behind a login the phone client cannot do.
          out = client.wait_until_succeeds(
              f"curl -sk --max-time 10 "
              f"--resolve ntfy.svc.idanreed.com:443:{svc_ip} "
              "https://ntfy.svc.idanreed.com/v1/health -w '\\n%{http_code}'",
              timeout=120,
          )
          code = out.strip().splitlines()[-1]
          assert code == "200", f"ntfy through caddy returned {code}: {out!r}"
          assert "healthy" in out, f"ntfy health body missing: {out!r}"
    '';
}
