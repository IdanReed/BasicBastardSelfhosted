{ config, pkgs, lib, ... }:

# TLS terminator for the VPS.
#
# Exists because Headscale and Authentik both need to be reachable over HTTPS
# on the standard port under different hostnames, and only one process can own
# :443. Previously Headscale bound 0.0.0.0:443 and ran its own ACME client,
# which left auth.idanreed.com — the OIDC issuer Headscale itself points at —
# with nothing listening on it, so OIDC discovery resolved to Headscale and got
# a 404. Because oidc.only_start_if_oidc_is_available is false, that failed
# silently as "login doesn't work" rather than as a startup error.
#
# HTTP-01 is used rather than DNS-01: this host is publicly reachable on :80,
# so no DNS-provider plugin — and therefore no custom Caddy build — is needed.
# The services VM still needs DNS-01 because it is tailnet-only and Let's
# Encrypt cannot reach it.
#
# Requires public A records for BOTH names pointing at this VPS:
#   headscale.idanreed.com  A  <vps-public-ip>
#   auth.idanreed.com       A  <vps-public-ip>

{
  services.caddy = {
    enable = true;

    # ACME account contact. Let's Encrypt uses this for expiry warnings.
    email = "admin@idanreed.com";

    # Trust X-Forwarded-* from tailnet sources. The forward-auth hop from the
    # services VM's Caddy (stacks/caddy/Caddyfile, the (protected) snippet)
    # arrives over the tailnet, and Authentik's embedded outpost routes
    # forward-auth requests BY X-Forwarded-Host — Caddy replaces that header
    # on requests from untrusted sources (anti-spoofing), so without this the
    # outpost only ever sees auth.idanreed.com and 404s every forward-auth
    # check. 100.64.0.0/10 is the CGNAT range headscale allocates from: not
    # publicly routable, and a TCP connection cannot complete with a spoofed
    # source address, so only genuine tailnet peers match. Covered by
    # tests/suites/forward-auth.nix, including the negative (a spoofed
    # X-Forwarded-Host from a non-tailnet source stays stripped).
    globalConfig = ''
      servers {
        trusted_proxies static 100.64.0.0/10
      }
    '';

    virtualHosts."headscale.idanreed.com".extraConfig = ''
      # HSTS (security review 2026-08-30 item 6). includeSubDomains here only
      # covers *.headscale.idanreed.com — apex-wide coverage would have to be
      # served by whatever hosts idanreed.com itself (vps-personal), which is
      # outside this repo. Still cheap and correct for this name.
      header Strict-Transport-Security "max-age=31536000; includeSubDomains"

      # Headscale listens on loopback only (modules/headscale.nix).
      # reverse_proxy passes WebSocket upgrades through unchanged, which the
      # embedded DERP relay at /derp depends on. STUN is UDP/3478 and does not
      # pass through here at all.
      reverse_proxy 127.0.0.1:8080
    '';

    virtualHosts."auth.idanreed.com".extraConfig = ''
      # HSTS (security review 2026-08-30 item 6).
      #
      # What this header does, stated correctly — the previous version of this
      # comment claimed HSTS was "the cheap mitigation" for the apex cookie
      # scope, and that is simply not what HSTS does. HSTS pins the BROWSER to
      # HTTPS for this name: it removes the plaintext downgrade and the
      # sslstrip-style MITM. It has no effect whatsoever on which hosts a
      # cookie is sent to.
      #
      # The cookie risk is therefore UNMITIGATED and accepted, not reduced:
      # AUTHENTIK_COOKIE_DOMAIN is the apex (required, or the forward-auth
      # outpost's session is invisible to *.svc.idanreed.com), so the Authentik
      # session cookie is attached to requests to EVERY idanreed.com
      # subdomain — including names this repo does not run, e.g. whatever
      # serves the apex. Any one of them that is compromised or
      # attacker-controlled can read the cookie out of the request it receives
      # and replay it here. HTTPS everywhere does not change that; it only
      # means the theft happens over TLS.
      #
      # The actual mitigations, neither of which is taken: narrow the cookie
      # domain (breaks forward auth, which is the whole reason it is the apex),
      # or stop sharing an apex with anything not equally trusted.
      #
      # Scoping truth as above: includeSubDomains here only covers
      # *.auth.idanreed.com; apex-wide HSTS must be served by the apex host
      # (vps-personal), which is outside this repo.
      header Strict-Transport-Security "max-age=31536000; includeSubDomains"

      # Security review 2026-08-30 item 5: the admin UI and the API do not
      # need to be public — only login flows do (OIDC redirects arrive from
      # browsers anywhere). BUT the login page is itself a SPA that calls
      # authentik's own API from the browser, so the endpoints it needs must
      # stay public or every public login breaks with an opaque JS error.
      # /outpost.goauthentik.io/* (forward-auth checks) is a different prefix
      # and deliberately not matched here.
      #
      # WHY THE CARVE-OUT IS EXACTLY THESE TWO PREFIXES, and why the flows
      # half is now `executor` rather than all of `flows`:
      #   - web/src/flow/FlowExecutor.ts issues precisely two API calls,
      #     flowsExecutorGet and flowsExecutorSolve — i.e. GET and POST on
      #     /api/v3/flows/executor/<slug>/. Nothing in the flow bundle touches
      #     any other /api/v3/flows/ route.
      #   - Corroborated locally: the verbatim login POST captured against the
      #     pinned image for the fail2ban filter (../configuration.nix, the
      #     authentik.conf sample line) is
      #     "path": "/api/v3/flows/executor/default-authentication-flow/".
      #   - /api/v3/root/* is the branding/config fetch the executor shell
      #     needs before it can render anything.
      # The rest of /api/v3/flows/* — instances/, bindings/, stages/,
      # inspector/ — is flow CRUD and the flow inspector: admin surface with
      # no unauthenticated caller, and precisely what item 5 wanted off the
      # public internet. Narrowing therefore keeps every public login working
      # and takes the flow-administration API back behind the tailnet.
      # tests/suites/vps.nix already asserts the kept path
      # (/api/v3/flows/executor/default/) reaches the backend from off-tailnet.
      #
      # Allowed sources: the tailnet (admin access arrives over it once
      # headscale extra_records maps auth.idanreed.com to the VPS tailnet IP
      # — operator step after first deploy; until then: ssh -L 9000) and
      # loopback (local curl/ops on the VPS itself).
      @restricted {
        path /if/admin* /api/v3/*
        not path /api/v3/flows/executor/* /api/v3/root/*
        not remote_ip 100.64.0.0/10 127.0.0.0/8 ::1
      }
      respond @restricted "restricted to tailnet" 403

      # Authentik's HTTP listener. Its HTTPS listener (9443, self-signed) is
      # not published at all now — this is the only TLS path in.
      reverse_proxy 127.0.0.1:9000
    '';
  };

  # Caddy is the only public listener on this host, so its failure takes
  # HTTPS for headscale AND authentik with it — and the embedded DERP relay,
  # which is proxied at /derp. Established WireGuard sessions survive (that is
  # why the notifier can still reach ntfy over the tailnet), but nothing new
  # can register. See notify-failure@ in ../configuration.nix for the honest
  # limits of that delivery path; the out-of-band backstop is the Gatus probe
  # pair in stacks/gatus/gatus.yaml, which dials both public names from the
  # services VM over the internet.
  # No startLimit* override is needed here, unlike headscale.service and
  # tailscale-autoconnect.service. Read off the built unit, not assumed: the
  # nixpkgs caddy module ships StartLimitIntervalSec=14400 and
  # StartLimitBurst=10 alongside Restart=on-failure/RestartSec=5s, so ten
  # rapid failures reach the limit in ~50s and the unit genuinely enters
  # `failed` — which is the state OnFailure keys on. It also sets
  # RestartPreventExitStatus=1, so a Caddyfile that does not parse fails on
  # the first try instead of looping.
  systemd.services.caddy.onFailure = [ "notify-failure@%n.service" ];
}
