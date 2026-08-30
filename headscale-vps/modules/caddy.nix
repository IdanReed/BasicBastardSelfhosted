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
      # HSTS (security review 2026-08-30 item 6): AUTHENTIK_COOKIE_DOMAIN is
      # the apex (required for forward-auth), so the session cookie travels to
      # every subdomain — an accepted risk whose cheap mitigation is strict
      # transport. Scoping truth as above: full apex-wide protection needs the
      # apex host to serve includeSubDomains; this covers auth.* itself.
      header Strict-Transport-Security "max-age=31536000; includeSubDomains"

      # Security review 2026-08-30 item 5: the admin UI and the API do not
      # need to be public — only login flows do (OIDC redirects arrive from
      # browsers anywhere). BUT the login page is itself a SPA that calls
      # /api/v3/flows/* (flow executor) and /api/v3/root/* (branding/config)
      # from the browser, so those two API prefixes must stay public or
      # every login breaks. /outpost.goauthentik.io/* (forward-auth checks)
      # is a different prefix and deliberately not matched here.
      #
      # Allowed sources: the tailnet (admin access arrives over it once
      # headscale extra_records maps auth.idanreed.com to the VPS tailnet IP
      # — operator step after first deploy; until then: ssh -L 9000) and
      # loopback (local curl/ops on the VPS itself).
      @restricted {
        path /if/admin* /api/v3/*
        not path /api/v3/flows/* /api/v3/root/*
        not remote_ip 100.64.0.0/10 127.0.0.0/8 ::1
      }
      respond @restricted "restricted to tailnet" 403

      # Authentik's HTTP listener. Its HTTPS listener (9443, self-signed) is
      # not published at all now — this is the only TLS path in.
      reverse_proxy 127.0.0.1:9000
    '';
  };
}
