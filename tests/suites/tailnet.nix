# Both hosts, one tailnet, end to end.
#
# This is the suite that covers the seam the other two cannot: the services VM
# joining the tailnet the VPS serves, and Caddy on the services VM binding the
# address that join produced. Everything up to that point can be green while
# the actual production path is broken, because the address only exists once a
# real tailnet does.
#
# Genuinely under test:
#   - tailscale-autoconnect on BOTH hosts, including --login-server, which is
#     the flag whose absence makes a node register against Tailscale's SaaS and
#     silently never appear on the tailnet
#   - Caddy on the services VM binding only the tailnet IP, verified from a
#     third host rather than by reading the Caddyfile
#   - a client reaching a service through Caddy over the tailnet, by hostname
#   - an off-tailnet host reaching none of it
#   - the loopback-only publish contract probed from ON the tailnet — the
#     services suite's outsider can only prove firewall posture, because the
#     interface that would expose a 0.0.0.0 bind is the trusted tailscale0,
#     and only this suite has a peer on it
#   - policy.hujson admitting the traffic it is supposed to admit

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
    images."ghcr_io_idanreed_caddy-cloudflare_2_11_2"
  ];

  # caddy needs /var/lib/test-ca in-container for the trust_pool line above
  caddyTestOverride = pkgs.writeText "caddy-test-override.yaml" ''
    services:
      caddy:
        volumes:
          - /var/lib/test-ca:/var/lib/test-ca:ro
  '';

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

        # trust_pool: verify the VPS's pebble cert on the forward_auth hop
        # (same injection as forward-auth.nix; arcane is `import protected`)
        fa = re.compile(
            r"(\n\t\ttransport http \{\n"
            r"\t\t\ttls_server_name auth\.idanreed\.com\n)")
        out, n = fa.subn(
            r"\1\t\t\ttls_trust_pool file /var/lib/test-ca/bundle.pem\n",
            out,
        )
        if n != 1:
            print(f"expected one (protected) transport block, found {n}", file=sys.stderr)
            sys.exit(1)
        open(os.environ["out"], "w").write(out)
        PY
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
  name = "tailnet";

  nodes = {
    vps =
      { nodes, ... }:
      {
        imports = [
          sopsModule
          ../../headscale-vps/configuration.nix
          ../../headscale-vps/modules/caddy.nix
          ../../headscale-vps/modules/headscale.nix
          # The REAL authentik, so backup-prepare's cross-host dump has a real
          # authentik_db to pg_dumpall through ssh+sudo+docker.
          ../../headscale-vps/modules/authentik.nix

          profiles.noBootloader
          profiles.noDhcp
          profiles.manualTailscaleAutoconnect
          # Authorises the committed test key for idan — the same key seeded
          # on the services VM as /var/lib/backup/vps_ed25519, so the pull
          # rides the production user/sudo path.
          profiles.testSshAccess
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
          # backup-prepare's VPS pull identity is NOT planted here any more:
          # the sops fixture's BACKUP_VPS_SSH_KEY carries the committed test
          # key, so sops-nix installs it at /var/lib/backup/vps_ed25519 (the
          # production path — a symlink into /run/secrets.d, which host-side
          # ssh follows fine). profiles.testSshAccess authorises its public
          # half for idan on the vps node, so the pull below rides the full
          # sops -> ssh -> sudo production chain. A test C+ rule would
          # overwrite the symlink and mask a broken delivery.
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

    # Stands in for a laptop on the tailnet.
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

    # Never joins the tailnet. Anything it can reach is reachable from the LAN.
    outsider =
      { nodes, ... }:
      {
        security.pki.certificateFiles = [ nodes.acme.test-support.acme.caCert ];
      };
  };

  testScript =
    { nodes, ... }:
    ''
      import json

      # Pebble's per-run issuing root, fetched at runtime by
      # profiles.pebbleTrust. Used for every assertion against the VPS's
      # public names. The *.svc.idanreed.com assertions below use -k instead:
      # the services VM's Caddy runs `tls internal` in the suite (a test
      # substitution for DNS-01 — see testCaddyfile), so its CA is per-run
      # Caddy-generated and proves nothing about production.
      CA = "--cacert /var/lib/test-ca/bundle.pem"

      start_all()
      acme.wait_for_unit("pebble.service")

      # -----------------------------------------------------------------------
      # Control plane
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

      def join(machine, secret_path):
          # Overwrite the decrypted placeholder in place and restart, so the
          # unit that runs is the real tailscale-autoconnect, --login-server
          # and all.
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

      # -----------------------------------------------------------------------
      # Both hosts join the tailnet
      # -----------------------------------------------------------------------
      with subtest("the services VM joins the tailnet via --login-server"):
          services_vm.wait_for_unit("bootstrap-komodo.service")
          svc_ip = join(services_vm,
                        "${nodes.services.sops.secrets.TAILSCALE_AUTH_KEY.path}")
          assert svc_ip.startswith("100."), f"services-vm got {svc_ip!r}"

          # Registered against *this* headscale, not Tailscale's SaaS.
          nodes_json = json.loads(
              headscale_vps.succeed("headscale nodes list -o json"))
          names = [n["given_name"] for n in nodes_json]
          assert "services-vm" in names, f"headscale does not know it: {names}"

      with subtest("the VPS joins the tailnet it serves"):
          vps_ip = join(headscale_vps,
                        "${nodes.vps.sops.secrets.TAILSCALE_AUTH_KEY.path}")
          assert vps_ip.startswith("100."), f"vps got {vps_ip!r}"

      with subtest("a client joins"):
          client.wait_for_unit("tailscaled.service")
          key = authkey()
          client.succeed(
              f"tailscale up --login-server https://${headscaleHost} "
              f"--auth-key {key} --hostname client"
          )
          client.wait_until_succeeds(
              "tailscale status --json | jq -e '.BackendState == \"Running\"'",
              timeout=120,
          )

      with subtest("peers route to each other"):
          client.wait_until_succeeds(f"ping -c 3 -W 5 {svc_ip}", timeout=90)
          client.wait_until_succeeds(f"ping -c 3 -W 5 {vps_ip}", timeout=90)

      # -----------------------------------------------------------------------
      # Caddy binds the address the tailnet handed out
      # -----------------------------------------------------------------------
      with subtest("Caddy binds only the tailnet IP"):
          # TAILNET_IP is a secret on the real host because it is not known
          # until the node has joined. Same thing here: rewrite it, then bring
          # the stack up as Arcane would.
          services_vm.succeed(
              f"sed -i 's|^TAILNET_IP=.*|TAILNET_IP={svc_ip}|' /srv/stacks/caddy/.env"
          )
          services_vm.succeed(
              "docker compose -f /srv/stacks/caddy/compose.yaml "
              "-f ${caddyTestOverride} -p caddy "
              "up -d --wait --wait-timeout 180"
          )
          services_vm.wait_for_open_port(443, addr=svc_ip)

          listeners = services_vm.succeed("ss -ltnH '( sport = :443 )'")
          assert f"{svc_ip}:443" in listeners, listeners
          # A bare `bind` — or an unset TAILNET_IP — would put Caddy on
          # 0.0.0.0, serving the LAN as well as the tailnet.
          assert "0.0.0.0:443" not in listeners and "*:443" not in listeners, \
              f"Caddy is not bound to the tailnet IP alone: {listeners}"

      # -----------------------------------------------------------------------
      # The production path, from a client
      # -----------------------------------------------------------------------
      with subtest("a tailnet client reaches Komodo through Caddy by hostname"):
          services_vm.wait_for_unit("bootstrap-komodo.service")
          services_vm.wait_until_succeeds(
              "curl -sf --max-time 5 http://127.0.0.1:10000/ -o /dev/null", timeout=300
          )

          # *.svc.idanreed.com is a public A record pointing at the tailnet IP
          # on the real network. /etc/hosts is a read-only store symlink on
          # NixOS, so --resolve stands in for that record per request.
          # retry until 2xx/3xx: a cold embedded outpost 503s the first
          # protected requests while it loads applications, and the bare
          # http_code curl "succeeds" on a 503, so poll on the code itself.
          client.wait_until_succeeds(
              f"test $(curl -sk --max-time 10 "
              f"--resolve komodo.svc.idanreed.com:443:{svc_ip} "
              "https://komodo.svc.idanreed.com/ "
              "-o /dev/null -w '%{http_code}') -lt 400", timeout=180
          )

      with subtest("unknown subdomains 404 rather than returning a blank 200"):
          out = client.succeed(
              f"curl -sk --max-time 10 "
              f"--resolve nope.svc.idanreed.com:443:{svc_ip} "
              "https://nope.svc.idanreed.com/ -w '\\n%{http_code}'"
          )
          assert "No such service" in out, f"got {out!r}"

      # -----------------------------------------------------------------------
      # MagicDNS
      # -----------------------------------------------------------------------
      with subtest("MagicDNS resolves the VPS by its tailnet name"):
          # backup-prepare's default VPS_HOST is the MagicDNS name, so this is
          # a production dependency, not a nicety. tailscaled rewrites the
          # client's resolver config when accept-dns is on (the default).
          try:
              services_vm.wait_until_succeeds(
                  "getent hosts headscale-vps.tailnet.idanreed.com", timeout=60
              )
          except Exception:
              print(services_vm.execute("cat /etc/resolv.conf")[1])
              print(services_vm.execute("tailscale status")[1])
              raise

      # -----------------------------------------------------------------------
      # backup-prepare, the green path: cross-host dumps over the tailnet
      # -----------------------------------------------------------------------
      # The half the services suite cannot cover: ssh as idan to the VPS over
      # the tailnet by MagicDNS name, sudo docker exec a REAL authentik_db for
      # pg_dumpall, rsync /var/lib/headscale (db + noise key — the
      # control-plane identity) — then the success stamp, and the staleness
      # canary flipping green because of it.
      with subtest("backup-prepare pulls VPS state and stamps success"):
          headscale_vps.wait_until_succeeds(
              "systemctl is-active --quiet authentik.service", timeout=900
          )
          try:
              services_vm.succeed("systemctl start backup-prepare.service")
          except Exception:
              print(services_vm.execute(
                  "journalctl -u backup-prepare --no-pager | tail -40")[1])
              raise

          services_vm.succeed("test -s /mnt/fast/_vps/authentik.sql")
          services_vm.succeed(
              "grep -q 'CREATE ROLE authentik' /mnt/fast/_vps/authentik.sql")
          services_vm.succeed("test -s /mnt/fast/_vps/headscale/db.sqlite")
          services_vm.succeed("test -s /mnt/fast/_vps/headscale/noise_private.key")
          # The green path stamps BOTH legs — local dumps and the VPS pull are
          # separate stamps precisely so a tailnet blip cannot mark local
          # dumps stale (and vice versa). Here everything worked, so both.
          services_vm.succeed("test -s /mnt/fast/_dumps/.last-success-local")
          services_vm.succeed("test -s /mnt/fast/_dumps/.last-success-vps")

          # The canary that alerts on stale backups must consider THIS fresh.
          services_vm.succeed("systemctl start backup-staleness-check.service")

      # -----------------------------------------------------------------------
      # Loopback-only publishing, probed from ON the tailnet
      # -----------------------------------------------------------------------
      # This is the real threat model for the 127.0.0.1 publish addresses:
      # both hosts trust tailscale0 wholesale, so the firewall does nothing on
      # that interface and only the bind address keeps raw service ports off
      # the tailnet. The services suite's outsider cannot see this — it sits
      # behind the firewall. Only a genuine tailnet peer can.
      with subtest("loopback-bound ports are unreachable from a tailnet peer"):
          # Bring ntfy up so its 10001 probe tests a live listener rather
          # than an empty port (nothing else in this suite starts it).
          services_vm.succeed(
              "docker compose -f /srv/stacks/ntfy/compose.yaml -p ntfy "
              "up -d --wait --wait-timeout 180"
          )

          # Liveness controls: each service really is listening on loopback,
          # so the negatives below cannot pass vacuously against a dead port.
          services_vm.succeed(
              "curl -sf --max-time 5 http://127.0.0.1:10000/ -o /dev/null")
          services_vm.succeed(
              "curl -sf --max-time 5 http://127.0.0.1:10001/v1/health -o /dev/null")
          headscale_vps.succeed(
              "curl -sf --max-time 5 http://127.0.0.1:9090/metrics -o /dev/null")

          # Positive control on the same route: the tailnet path to the
          # services VM works, so a failure below means "refused", not
          # "tailnet down".
          client.succeed(f"nc -z -w 5 {svc_ip} 443")

          # Arcane (docker socket = root-equivalent) and ntfy must not answer
          # on the tailnet IP.
          client.fail(f"nc -z -w 5 {svc_ip} 10000")
          client.fail(f"curl -sf --max-time 5 http://{svc_ip}:10000/ -o /dev/null")
          client.fail(f"nc -z -w 5 {svc_ip} 10001")
          client.fail(f"curl -sf --max-time 5 http://{svc_ip}:10001/v1/health -o /dev/null")

          # Headscale's metrics endpoint on the VPS is loopback-bound for the
          # same reason; the tailnet must not see it either.
          client.fail(f"nc -z -w 5 {vps_ip} 9090")
          client.fail(f"curl -sf --max-time 5 http://{vps_ip}:9090/metrics -o /dev/null")

      # -----------------------------------------------------------------------
      # Nothing leaks off the tailnet
      # -----------------------------------------------------------------------
      with subtest("an off-tailnet host reaches none of it"):
          # The services VM trusts tailscale0 wholesale, so this is the only
          # thing standing between the LAN and every service on the host.
          outsider.fail("curl -sk --max-time 5 https://services-vm/ -o /dev/null")
          outsider.fail("nc -z -w 5 services-vm 10000")
          outsider.fail("nc -z -w 5 services-vm 10001")
          outsider.fail("nc -z -w 5 services-vm 443")
          # Only SSH is open on a non-tailnet interface.
          outsider.succeed("nc -z -w 5 services-vm 22")
    '';
}
