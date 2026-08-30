# Headscale VPS: Caddy + Headscale, with a real ACME issuance and a real
# tailnet.
#
# Mirrors headscale-vps/ as closely as a VM can. What is NOT overridden, and so
# is genuinely under test:
#   - Caddy owning :443 alone, reverse-proxying loopback services
#   - Headscale on 127.0.0.1:8080 with no TLS of its own
#   - Caddy's real ACME client, doing a real HTTP-01 challenge
#   - the firewall from configuration.nix
#   - policy.hujson, loaded by the running server
#   - sops-nix decrypting secrets at activation, with real owners and modes
#   - sshd's auth surface: key login, no passwords, no root
#   - tailscale-autoconnect joining the tailnet this host serves
#
# What is overridden, and why, is in ../lib/profiles.nix. The only suite-local
# override is the ACME endpoint: Let's Encrypt is unreachable from a sandboxed
# VM, so Caddy is pointed at the Pebble server from nixpkgs' own test suite.
# The client, the challenge, and the certificate installation are all real; only
# the CA differs (and Pebble regenerates its issuing root per run — see
# profiles.pebbleTrust for how nodes come to trust it).

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
in
pkgs.testers.runNixOSTest {
  name = "vps";

  nodes = {
    # ---------------------------------------------------------------------
    # The host under test
    # ---------------------------------------------------------------------
    vps =
      { config, nodes, ... }:
      {
        imports = [
          sopsModule
          ../../headscale-vps/configuration.nix
          ../../headscale-vps/modules/caddy.nix
          ../../headscale-vps/modules/headscale.nix

          profiles.noBootloader
          profiles.noDhcp
          profiles.manualTailscaleAutoconnect
          profiles.testSshAccess
          (profiles.sopsFixture ../fixtures/vps.sops.yaml)
          (profiles.pebbleTrust {
            caDomain = nodes.acme.test-support.acme.caDomain;
            caCert = nodes.acme.test-support.acme.caCert;
          })
          (profiles.sized {
            memoryMB = 2048;
            diskMB = 4096;
          })
        ];

        # Point Caddy's ACME client at Pebble. This is the one behavioural
        # override in the suite: the ACME *protocol* exchange is real, but
        # Let's Encrypt cannot reach a VM on an isolated vlan.
        #
        # Coverage lost: nothing about Caddy's configuration, but the
        # production ACME endpoint and the public A records it depends on are
        # not exercised. Those are only verifiable against real DNS.
        services.caddy.globalConfig = lib.mkAfter ''
          acme_ca https://${nodes.acme.test-support.acme.caDomain}/dir
        '';

        security.pki.certificateFiles = [ nodes.acme.test-support.acme.caCert ];

        # Both public names live on this host. On the real VPS these are public
        # A records; here /etc/hosts stands in for DNS.
        networking.hosts."127.0.0.1" = [
          headscaleHost
          authHost
        ];

        # Authentik is not in this suite, so nothing listens on 9000. Give
        # Caddy something to proxy for auth.idanreed.com, otherwise its ACME
        # order for that name succeeds but every request 502s and the failure
        # looks like a Caddy bug rather than an absent backend.
        services.nginx = {
          enable = true;
          virtualHosts."authentik-stand-in" = {
            listen = [
              {
                addr = "127.0.0.1";
                port = 9000;
              }
            ];
            locations."/".return = "200 'authentik-stand-in'";
          };
        };

        # The headscale CLI is what the suite drives the server with, and what
        # the break-glass path in the module's comments assumes is present.
        # Adding it is a harness convenience, not a behavioural change.
        environment.systemPackages = [ pkgs.headscale ];
      };

    # ---------------------------------------------------------------------
    # Pebble, standing in for Let's Encrypt
    # ---------------------------------------------------------------------
    acme =
      { nodes, lib, ... }:
      {
        imports = [ acmeServerModule ];

        # Pebble validates HTTP-01 by connecting to the requested name on :80,
        # so it has to resolve both names to the VPS.
        networking.hosts.${nodes.vps.networking.primaryIPAddress} = [
          headscaleHost
          authHost
        ];
      };

    # ---------------------------------------------------------------------
    # A tailnet peer — stands in for a laptop or the services VM
    # ---------------------------------------------------------------------
    peer =
      { nodes, ... }:
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
        # The status polls in the test script pipe through jq. Without this the
        # poll exits 127 forever and the subtest times out looking exactly like
        # a tailnet failure.
        environment.systemPackages = [ pkgs.jq ];
      };

    # ---------------------------------------------------------------------
    # Off-tailnet host, for the negative assertions
    # ---------------------------------------------------------------------
    # Everything this node can reach is, by definition, exposed to the public
    # internet on the real VPS. It also drives the SSH assertions: reachable
    # SSH is exactly the exposure the firewall intends, so exercise its auth
    # surface from here.
    outsider =
      { nodes, ... }:
      {
        security.pki.certificateFiles = [ nodes.acme.test-support.acme.caCert ];
        networking.hosts.${nodes.vps.networking.primaryIPAddress} = [
          headscaleHost
          authHost
        ];

        # The committed throwaway private key. environment.etc copies (not
        # symlinks) when a mode is given, which matters: ssh refuses
        # world-readable identity files, and store paths are world-readable.
        environment.etc."test-ssh-key" = {
          source = ../keys/test-ssh-key;
          mode = "0600";
        };
      };
  };

  testScript =
    { nodes, ... }:
    ''
      import json

      # Pebble's issuing root is fetched at runtime by profiles.pebbleTrust;
      # every https assertion verifies against this bundle. Never -k: an
      # unverified 200 would hide a wrong-name or wrong-chain certificate.
      CA = "--cacert /var/lib/test-ca/bundle.pem"

      SSH = ("ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
             "-o ConnectTimeout=10 -o BatchMode=yes")

      start_all()

      acme.wait_for_unit("pebble.service")

      # ---------------------------------------------------------------------
      # Secrets
      # ---------------------------------------------------------------------
      # sops-nix runs at activation, so a decryption or ownership failure shows
      # up as a failed boot rather than as a broken service later.
      headscale_vps.wait_for_unit("headscale.service")

      with subtest("sops secrets decrypt with the right owner and mode"):
          # modules/headscale.nix pins this to the headscale service user at
          # 0400. If the nixpkgs module ever renames that user, the file lands
          # unreadable and headscale starts without OIDC — silently, because
          # only_start_if_oidc_is_available is false.
          secret = "${nodes.vps.sops.secrets.HEADSCALE_OIDC_CLIENT_SECRET.path}"
          owner_mode = headscale_vps.succeed(f"stat -c '%U %a' {secret}").strip()
          assert owner_mode == "headscale 400", \
              f"OIDC secret is {owner_mode!r}, expected 'headscale 400'"

          # Exact equality on purpose: with the old dotenv layout this file
          # contained the WHOLE decrypted document (sops-install-secrets never
          # applies the per-secret key for dotenv — the finding that forced the
          # migration to secrets.sops.yaml). `==` is what keeps that fixed.
          val = headscale_vps.succeed(f"cat {secret}").strip()
          assert val == "test0oidc0client0secret0deadbeef0deadbeef0dead", \
              f"OIDC secret is not the bare value: {val!r}"

      # ---------------------------------------------------------------------
      # Headscale binding
      # ---------------------------------------------------------------------
      with subtest("headscale listens on loopback only"):
          headscale_vps.wait_for_open_port(8080, addr="127.0.0.1")
          listeners = headscale_vps.succeed("ss -ltnH '( sport = :8080 )'")
          # A regression to address = "0.0.0.0" would publish the control plane
          # directly, bypassing Caddy and its TLS.
          assert "127.0.0.1:8080" in listeners, listeners
          assert "0.0.0.0:8080" not in listeners, \
              f"headscale is bound to all interfaces: {listeners}"

      with subtest("metrics are loopback-only"):
          headscale_vps.succeed("curl -sf http://127.0.0.1:9090/metrics -o /dev/null")
          outsider.fail("curl -sf --max-time 5 http://headscale-vps:9090/metrics -o /dev/null")

      # ---------------------------------------------------------------------
      # Caddy + ACME
      # ---------------------------------------------------------------------
      headscale_vps.wait_for_unit("caddy.service")
      headscale_vps.wait_for_open_port(443)

      def caddy_diag(machine):
          # wait_until_succeeds' `timeout` counts retries, not seconds, and each
          # failed curl burns its own --max-time. A silent grind tells you
          # nothing, so dump what Caddy actually did on the way out.
          for label, cmd in [
              ("caddy journal", "journalctl -u caddy --no-pager -o cat | tail -40"),
              ("certificates", "find /var/lib/caddy -name '*.crt' 2>/dev/null | head"),
              ("tls handshake", f"curl -sv {CA} --max-time 8 https://${headscaleHost}/health 2>&1 | tail -25"),
              ("https /health code", "curl -sk --max-time 8 -o /dev/null -w '%{http_code}' https://${headscaleHost}/health"),
              ("bundle", "ls -la /var/lib/test-ca/ 2>&1"),
          ]:
              print(f"=== {label} ===")
              print(machine.execute(cmd)[1])

      with subtest("caddy obtains a certificate over HTTP-01 and proxies headscale"):
          # Issuance races startup; Caddy retries with backoff.
          try:
              headscale_vps.wait_until_succeeds(
                  f"curl -sf {CA} --max-time 5 https://${headscaleHost}/health", timeout=120
              )
          except Exception:
              caddy_diag(headscale_vps)
              raise
          # Served to another host, chain fully verified, so a cert for the
          # wrong name or from the wrong chain fails here.
          peer.wait_until_succeeds(
              f"curl -sf {CA} --max-time 5 https://${headscaleHost}/health", timeout=60
          )

      with subtest("auth.idanreed.com is served too"):
          # The bug modules/caddy.nix was written to fix: this name previously
          # had nothing listening, so OIDC discovery 404'd through headscale.
          peer.wait_until_succeeds(
              f"curl -sf {CA} --max-time 5 https://${authHost}/ -o /dev/null", timeout=60
          )

      with subtest("HSTS on both vhosts; admin/API prefixes are tailnet-only"):
          # Security review 2026-08-30 items 5+6. The peer's source address
          # here is its LAN IP — NOT 100.64/10 — so it stands in for the
          # public internet against the @restricted matcher.
          for host in ["${headscaleHost}", "${authHost}"]:
              hdrs = peer.succeed(
                  f"curl -s {CA} -o /dev/null -D - https://{host}/"
              ).lower()
              assert "strict-transport-security" in hdrs \
                  and "includesubdomains" in hdrs, (
                  f"{host} serves no HSTS/includeSubDomains: {hdrs!r}"
              )

          # Blocked from off-tailnet: the admin UI and the API proper. The
          # body pins WHICH layer refused — Caddy's matcher, not the backend.
          for path in ["/if/admin/", "/api/v3/core/users/"]:
              body = peer.succeed(f"curl -s {CA} https://${authHost}{path}")
              assert "restricted to tailnet" in body, (
                  f"{path} not blocked by the Caddy matcher: {body!r}"
              )

          # But the login SPA's API surface stays public — the flow executor
          # and branding config are called from arbitrary browsers during
          # LOGIN, so blocking them breaks every public login (the authentik
          # frontend is an SPA; this is the classic hardening footgun).
          for path in ["/api/v3/flows/executor/default/", "/api/v3/root/config/"]:
              body = peer.succeed(f"curl -s {CA} https://${authHost}{path}")
              assert "authentik-stand-in" in body, (
                  f"login-required API path {path} did not reach the "
                  f"backend: {body!r}"
              )

      # ---------------------------------------------------------------------
      # Firewall
      # ---------------------------------------------------------------------
      # Not "only 22, 80 and 443": proving *only* would need a full port scan,
      # which this driver has no business spending minutes on. Instead a
      # curated sweep of every port something on this host binds, bound, or
      # is conventionally expected to bind — the ports whose exposure has
      # actually bitten or would actually hurt.
      with subtest("22, 80, 443 answer; the curated leak candidates do not"):
          outsider.succeed("nc -z -w 5 headscale-vps 443")
          outsider.succeed("nc -z -w 5 headscale-vps 80")
          outsider.succeed("nc -z -w 5 headscale-vps 22")
          # Why each candidate: 8080 = headscale itself, reachable would
          # bypass Caddy and its TLS; 9000/9443 = Authentik HTTP/HTTPS, open
          # before modules/caddy.nix landed — the original leak; 9090 =
          # headscale metrics, loopback-bound above but the firewall is the
          # backstop; 10000 = the homelab port-block convention, where a
          # stack lands by habit; 3478 = STUN, UDP-only in the firewall, so
          # its TCP twin must stay shut.
          for port in [8080, 9000, 9090, 9443, 10000, 3478]:
              outsider.fail(f"nc -z -w 5 headscale-vps {port}")

      # ---------------------------------------------------------------------
      # SSH auth surface
      # ---------------------------------------------------------------------
      # Port 22 is deliberately public, so what sshd accepts IS the exposure.
      # The key is the committed test keypair authorised by
      # profiles.testSshAccess, merged alongside the production list — which
      # is ssh-pubkeys.nix entries filtered for null, so until Idan fills
      # them the real host authorises nothing (the ssh-pubkey-parity lint
      # WARNs while entries are null).
      with subtest("key login works, passwords and root are refused"):
          outsider.succeed(
              f"{SSH} -i /etc/test-ssh-key idan@headscale-vps true"
          )

          # Passwordless sudo for wheel, over the same channel.
          outsider.succeed(
              f"{SSH} -i /etc/test-ssh-key idan@headscale-vps sudo -n true"
          )

          # The server must not OFFER password auth at all. BatchMode alone
          # cannot distinguish "password refused" from "could not type one",
          # so read the advertised methods from the handshake.
          methods = outsider.succeed(
              f"{SSH} -v -o PubkeyAuthentication=no idan@headscale-vps true 2>&1 "
              "| grep 'Authentications that can continue' | head -1 || true"
          )
          # publickey present proves the handshake actually reached auth —
          # without this, a dead sshd would vacuously pass the next assert.
          assert "publickey" in methods, \
              f"never saw the server's auth offer: {methods!r}"
          assert "password" not in methods, \
              f"sshd offers password authentication: {methods!r}"
          # keyboard-interactive is the PAM side door: OpenSSH defaults it ON
          # and UsePAM yes would honour it — PasswordAuthentication=false
          # alone does not close it (security review item 4). Before the
          # explicit KbdInteractiveAuthentication=false this passed only
          # because the accounts happen to be password-locked.
          assert "keyboard-interactive" not in methods, \
              f"sshd offers keyboard-interactive (PAM) auth: {methods!r}"
          # And a client that insists on it gets nowhere.
          outsider.fail(
              f"{SSH} -o PubkeyAuthentication=no "
              "-o KbdInteractiveAuthentication=yes "
              "-o PreferredAuthentications=keyboard-interactive "
              "idan@headscale-vps true"
          )

          # PermitRootLogin no — even with a valid key.
          outsider.fail(
              f"{SSH} -i /etc/test-ssh-key root@headscale-vps true"
          )

      with subtest("fail2ban is running"):
          # SSH is the one deliberately public auth surface, and fail2ban is
          # the rate limit on it. is-active is all a VM suite can honestly
          # assert: provoking a real ban would need repeated failed logins
          # and then races the 1h bantime against every later SSH subtest.
          headscale_vps.succeed("systemctl is-active fail2ban.service")

      with subtest("the authentik jail is loaded"):
          # Layer 1 of the login-hardening pair (configuration.nix): a
          # fail2ban jail on Authentik's login page. fail2ban-client lists
          # every jail it actually loaded, so a filter that failed to parse or
          # a jail that never started fails HERE rather than silently leaving
          # the login page unprotected. The authentik container is not in this
          # suite (nginx stubs :9000), so we assert the jail exists, not that
          # it bans — same honesty line as the sshd jail above.
          jails = headscale_vps.succeed("fail2ban-client status")
          assert "authentik" in jails, \
              f"authentik jail not loaded: {jails!r}"
          # status of the jail itself must resolve (proves the filter loaded).
          headscale_vps.succeed("fail2ban-client status authentik")

      with subtest("the deployed filter still matches a real login_failed line"):
          # The drift alarm. The failregex was captured empirically against
          # ghcr.io/goauthentik/server:2026.5.6; run the DEPLOYED filter
          # (/etc/fail2ban/filter.d/authentik.conf) against that captured
          # sample and demand EXACTLY one hit. If an authentik upgrade changes
          # the login_failed log shape, the pin count drops to 0 and this
          # fails loudly — before the jail silently stops banning in
          # production. The sample is the verbatim line from the capture, also
          # recorded in the filter file's own comment.
          sample = (
              '{"action": "login_failed", "auth_via": "unauthenticated", '
              '"client_ip": "203.0.113.77", "context": {"http_request": '
              '{"args": {}, "method": "POST", "path": '
              '"/api/v3/flows/executor/default-authentication-flow/", '
              '"request_id": "dd8c847ae65f4bd8b8f9b4a22c087385", '
              '"user_agent": "curl/8.19.0"}, "password": '
              '"********************", "stage": {"app": '
              '"authentik_stages_password", "model_name": "passwordstage", '
              '"name": "default-authentication-password", "pk": '
              '"c0ad2df11f11428a8ca68c73980bd067"}, "username": "akadmin"}, '
              '"domain_url": "127.0.0.1", "event": "Created Event", "host": '
              '"127.0.0.1:19000", "level": "info", "logger": '
              '"authentik.events.models", "pid": 184, "request_id": '
              '"dd8c847ae65f4bd8b8f9b4a22c087385", "schema_name": "public", '
              '"timestamp": "2026-08-30T19:25:26.527644", "user": {"email": '
              '"admin@idanreed.com", "pk": 4, "username": "akadmin"}}'
          )
          # Negative controls: events that also carry a client_ip but must
          # NEVER match — a successful login, an identification-stage
          # invalid_login, and an asgi access line. Without these, a filter
          # that dropped its login_failed gate would still pass the
          # single-line check (empirically confirmed: fail2ban-regex counts
          # matched lines, so over-match on one line is invisible).
          negatives = [
              '{"action": "login", "auth_via": "password", "client_ip": '
              '"203.0.113.77", "event": "Created Event", "logger": '
              '"authentik.events.models", "username": "akadmin"}',
              '{"action": "invalid_login", "auth_via": "unauthenticated", '
              '"client_ip": "203.0.113.77", "event": "Created Event", '
              '"logger": "authentik.events.models", "username": "nosuch"}',
              '{"client_ip": "203.0.113.77", "event": "/-/health/live/", '
              '"level": "info", "logger": "authentik.asgi", "method": "GET", '
              '"status": 204}',
          ]
          lines = "\n".join([sample] + negatives)
          headscale_vps.succeed(
              "install -m 0644 /dev/null /tmp/ak-sample.log"
          )
          headscale_vps.succeed(
              f"cat > /tmp/ak-sample.log <<'EOF'\n{lines}\nEOF"
          )
          out = headscale_vps.succeed(
              "fail2ban-regex /tmp/ak-sample.log "
              "/etc/fail2ban/filter.d/authentik.conf"
          )
          import re as _re
          m = _re.search(r"(\d+) matched", out)
          missed = _re.search(r"(\d+) missed", out)
          assert m and m.group(1) == "1", \
              f"filter did not match the captured sample exactly once:\n{out}"
          assert missed and missed.group(1) == "3", (
              "filter matched a negative control — it would ban successful "
              f"logins or health checks:\n{out}"
          )

      # ---------------------------------------------------------------------
      # Policy
      # ---------------------------------------------------------------------
      with subtest("policy.hujson is loaded by the running server"):
          # Positive first: ask the running server for its policy and demand
          # OUR content in it. Grepping the journal for error strings alone is
          # vacuous-by-wording — it passes just as happily when the strings
          # change across a headscale upgrade, or when no policy loaded at
          # all. tag:server is the anchor of policy.hujson's tagging workflow,
          # so its presence ties the served policy to the file in git.
          policy = headscale_vps.succeed("headscale policy get")
          assert "tag:server" in policy, \
              f"served policy does not contain tag:server: {policy[:2000]!r}"

          # Secondary signal: no rejection in the journal. Kept because a
          # rejected policy leaves the tailnet default-deny (totally
          # partitioned) and headscale logs it rather than refusing to start.
          journal = headscale_vps.succeed("journalctl -u headscale --no-pager")
          for bad in ["failed to load policy", "error parsing policy", "invalid policy"]:
              assert bad not in journal.lower(), \
                  f"headscale rejected the policy: {journal[-2000:]}"

      # ---------------------------------------------------------------------
      # A real tailnet
      # ---------------------------------------------------------------------
      with subtest("a peer joins the tailnet through Caddy"):
          headscale_vps.succeed("headscale users create idan")
          users = json.loads(headscale_vps.succeed("headscale users list -o json"))
          uid = str(users[0]["id"])

          key = headscale_vps.succeed(
              f"headscale preauthkeys create --user {uid} --reusable --expiration 24h"
          ).strip().splitlines()[-1]

          peer.wait_for_unit("tailscaled.service")
          peer.succeed(
              f"tailscale up --login-server https://${headscaleHost} --auth-key {key} "
              f"--hostname peer --accept-routes"
          )

          peer.wait_until_succeeds(
              "tailscale status --json | jq -e '.BackendState == \"Running\"'", timeout=60
          )
          ip = peer.succeed("tailscale ip -4").strip()
          assert ip.startswith("100."), f"peer got {ip!r}, expected CGNAT space"

      with subtest("the VPS joins the tailnet it serves"):
          # tailscale-autoconnect needs a real preauth key; the fixture ships a
          # placeholder. Overwrite the decrypted secret in place and restart, so
          # the unit under test is the real one — --login-server, health poll
          # and all.
          key = headscale_vps.succeed(
              f"headscale preauthkeys create --user {uid} --reusable --expiration 24h"
          ).strip().splitlines()[-1]
          secret = "${nodes.vps.sops.secrets.TAILSCALE_AUTH_KEY.path}"
          headscale_vps.succeed(f"install -m 0400 /dev/null {secret}.new")
          headscale_vps.succeed(f"printf '%s' '{key}' > {secret}.new")
          headscale_vps.succeed(f"mv {secret}.new {secret}")

          headscale_vps.succeed("systemctl restart tailscale-autoconnect.service")
          headscale_vps.wait_until_succeeds(
              "tailscale status --json | jq -e '.BackendState == \"Running\"'", timeout=120
          )
          vps_ip = headscale_vps.succeed("tailscale ip -4").strip()
          assert vps_ip.startswith("100."), f"vps got {vps_ip!r}"

      with subtest("peers reach each other over the tailnet"):
          peer.wait_until_succeeds(f"ping -c 3 -W 5 {vps_ip}", timeout=60)

      with subtest("a tailnet source reaches the admin UI"):
          # The positive half of the @restricted matcher: dialled at the
          # VPS's tailnet IP the request arrives over wireguard with a
          # 100.64/10 source and passes through to the backend. This is the
          # operator's admin path (split-DNS extra_records in production).
          body = peer.succeed(
              f"curl -s {CA} --resolve ${authHost}:443:{vps_ip} "
              f"https://${authHost}/if/admin/"
          )
          assert "authentik-stand-in" in body, (
              f"tailnet source blocked from the admin UI: {body!r}"
          )

      with subtest("the embedded DERP relay is advertised"):
          # derp.urls is deliberately empty so no Tailscale-operated relay is
          # used; region 999 is this host's own.
          netmap = json.loads(peer.succeed("tailscale debug netmap"))
          regions = netmap.get("DERPMap", {}).get("Regions", {})
          assert "999" in regions, f"embedded DERP region missing: {list(regions)}"
          assert len(regions) == 1, \
              f"expected only the embedded relay, got {list(regions)}"

      # ---------------------------------------------------------------------
      # Independence from the container runtime
      # ---------------------------------------------------------------------
      with subtest("headscale survives docker being stopped"):
          # The stated reason headscale is a native service rather than a
          # container: the tailnet must not depend on the container runtime.
          headscale_vps.succeed("systemctl stop docker.socket docker.service")
          headscale_vps.succeed("systemctl is-active headscale.service")
          headscale_vps.succeed(f"curl -sf {CA} --max-time 5 https://${headscaleHost}/health")
          headscale_vps.succeed("systemctl start docker.service")

      # ---------------------------------------------------------------------
      # Reboot
      # ---------------------------------------------------------------------
      with subtest("everything comes back after a reboot"):
          # Catches missing wantedBy/ordering, which only shows up on a cold
          # boot and not on the nixos-rebuild switch that deployed it.
          headscale_vps.shutdown()
          headscale_vps.start()
          headscale_vps.wait_for_unit("headscale.service")
          headscale_vps.wait_for_unit("caddy.service")
          headscale_vps.wait_until_succeeds(
              f"curl -sf {CA} --max-time 5 https://${headscaleHost}/health", timeout=120
          )

      # ---------------------------------------------------------------------
      # Nothing failed that the suite did not fail on purpose
      # ---------------------------------------------------------------------
      with subtest("no unit is left failed at suite end"):
          # This suite fails nothing deliberately (its outsider negatives are
          # connection refusals, not unit failures), so there is nothing to
          # reset-failed first — any entry here is a unit the assertions
          # above never looked at, failing quietly.
          failed = headscale_vps.succeed("systemctl --failed --no-legend").strip()
          assert failed == "", f"failed units at suite end:\n{failed}"
    '';
}
