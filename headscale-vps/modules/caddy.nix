{ config, pkgs, lib, ... }:

# TLS terminator for the VPS. Headscale and Authentik both need HTTPS on :443
# under different hostnames and only one process can own the port; when
# headscale owned it, auth.idanreed.com had nothing listening and OIDC
# discovery 404'd silently.
#
# HTTP-01, not DNS-01: this host is publicly reachable on :80, so no
# DNS-provider plugin and no custom Caddy build. Needs public A records for
# both headscale.idanreed.com and auth.idanreed.com.

{
  services.caddy = {
    enable = true;

    # ACME contact (expiry warnings)
    email = "admin@idanreed.com";

    # The forward-auth hop from the services VM's Caddy arrives over the
    # tailnet and the embedded outpost routes BY X-Forwarded-Host, which Caddy
    # strips from untrusted sources. 100.64.0.0/10 is headscale's CGNAT range:
    # not publicly routable, and TCP cannot complete with a spoofed source.
    globalConfig = ''
      servers {
        trusted_proxies static 100.64.0.0/10
      }
    '';

    virtualHosts."headscale.idanreed.com".extraConfig = ''
      # includeSubDomains covers only *.headscale.idanreed.com; apex-wide HSTS
      # must come from whatever serves the apex (outside this repo).
      header Strict-Transport-Security "max-age=31536000; includeSubDomains"

      # WebSocket upgrades pass through unchanged — the embedded DERP relay at
      # /derp depends on it. STUN is UDP/3478 and never touches Caddy.
      reverse_proxy 127.0.0.1:8080
    '';

    virtualHosts."auth.idanreed.com".extraConfig = ''
      # HSTS pins the browser to HTTPS. It does NOT narrow cookie scope:
      # AUTHENTIK_COOKIE_DOMAIN is the apex (required, or the forward-auth
      # session is invisible to *.svc.idanreed.com), so the session cookie
      # rides to every idanreed.com subdomain including hosts this repo does
      # not run. Accepted, unmitigated.
      header Strict-Transport-Security "max-age=31536000; includeSubDomains"

      # Admin UI + API off the public internet. The carve-out is exactly the
      # two prefixes the login SPA calls before authenticating — the flow
      # executor (web/src/flow/FlowExecutor.ts issues only GET/POST on
      # /api/v3/flows/executor/<slug>/) and /api/v3/root/* branding config.
      # The rest of /api/v3/flows/* is admin surface with no unauthenticated
      # caller, and /outpost.goauthentik.io/* is a different prefix,
      # deliberately unmatched. Allowed sources are the tailnet (headscale
      # extra_records maps auth.idanreed.com to this host's tailnet IP) and
      # loopback; remote_ip is the direct peer, so it cannot be spoofed
      # through the trusted_proxies rule above.
      @restricted {
        path /if/admin* /api/v3/*
        not path /api/v3/flows/executor/* /api/v3/root/*
        not remote_ip 100.64.0.0/10 127.0.0.0/8 ::1
      }
      respond @restricted "restricted to tailnet" 403

      # Authentik's HTTP listener; 9443 (self-signed) is not published.
      reverse_proxy 127.0.0.1:9000
    '';
  };

  # Caddy failing takes HTTPS for headscale and authentik with it, plus the
  # DERP relay. No startLimit* override needed: the nixpkgs module already
  # ships limits that let the unit reach `failed` (14400/10 with RestartSec=5s,
  # plus RestartPreventExitStatus=1 so an unparseable Caddyfile fails once).
  systemd.services.caddy.onFailure = [ "notify-failure@%n.service" ];
}
