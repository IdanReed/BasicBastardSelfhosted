{ config, pkgs, lib, ... }:

# TLS terminator for the VPS: Headscale and Authentik both need HTTPS on
# :443 under different hostnames, and only one process can own the port.
# When Headscale owned :443 itself, auth.idanreed.com — the OIDC issuer
# Headscale points at — had nothing listening, so OIDC discovery 404d; with
# only_start_if_oidc_is_available false that fails silently as "login
# doesn't work", not as a startup error.
#
# HTTP-01, not DNS-01: this host is publicly reachable on :80, so no
# DNS-provider plugin (no custom Caddy build). The services VM still needs
# DNS-01 — tailnet-only, Let's Encrypt cannot reach it.
#
# Requires public A records for BOTH names (headscale. and auth.idanreed.com)
# pointing at this VPS.

{
  services.caddy = {
    enable = true;

    # ACME contact (expiry warnings)
    email = "admin@idanreed.com";

    # Trust X-Forwarded-* from tailnet sources: the forward-auth hop from the
    # services VM's Caddy arrives over the tailnet, and the embedded outpost
    # routes BY X-Forwarded-Host — which Caddy strips from untrusted sources,
    # so without this the outpost only ever sees auth.idanreed.com and 404s
    # every check. 100.64.0.0/10 is headscale's CGNAT range: not publicly
    # routable, and TCP cannot complete with a spoofed source, so only
    # genuine tailnet peers match. Covered by tests/suites/forward-auth.nix,
    # including the spoofed-header negative.
    globalConfig = ''
      servers {
        trusted_proxies static 100.64.0.0/10
      }
    '';

    virtualHosts."headscale.idanreed.com".extraConfig = ''
      # HSTS (security review 2026-08-30 item 6). includeSubDomains covers
      # only *.headscale.idanreed.com; apex-wide HSTS must come from whatever
      # serves the apex (vps-personal, outside this repo).
      header Strict-Transport-Security "max-age=31536000; includeSubDomains"

      # WebSocket upgrades pass through unchanged — the embedded DERP relay
      # at /derp depends on that. STUN is UDP/3478 and never touches Caddy.
      reverse_proxy 127.0.0.1:8080
    '';

    virtualHosts."auth.idanreed.com".extraConfig = ''
      # HSTS (security review 2026-08-30 item 6): pins the BROWSER to HTTPS
      # (kills plaintext downgrade / sslstrip). It has NO effect on cookie
      # scope — the cookie risk is UNMITIGATED and accepted:
      # AUTHENTIK_COOKIE_DOMAIN is the apex (required, or the forward-auth
      # outpost session is invisible to *.svc.idanreed.com), so the session
      # cookie rides to EVERY idanreed.com subdomain, including hosts this
      # repo does not run — any compromised one can replay it here. The real
      # mitigations (narrow the cookie domain, or stop sharing the apex) both
      # break the design and are not taken.
      #
      # includeSubDomains covers only *.auth.idanreed.com; apex-wide HSTS
      # must be served by the apex host (outside this repo).
      header Strict-Transport-Security "max-age=31536000; includeSubDomains"

      # Security review 2026-08-30 item 5: admin UI + API off the public
      # internet; only login flows stay public — and the login page is a SPA
      # calling authentik's own API, so its endpoints must stay public or
      # every login breaks with an opaque JS error. /outpost.goauthentik.io/*
      # is a different prefix, deliberately not matched.
      #
      # The carve-out is EXACTLY these two prefixes:
      #   - web/src/flow/FlowExecutor.ts issues only flowsExecutorGet/Solve,
      #     i.e. GET/POST on /api/v3/flows/executor/<slug>/ — corroborated by
      #     the captured login POST in ../configuration.nix (authentik.conf
      #     sample line).
      #   - /api/v3/root/* is the branding/config fetch the executor shell
      #     needs before it renders.
      # The rest of /api/v3/flows/* (instances/, bindings/, stages/,
      # inspector/) is admin surface with no unauthenticated caller.
      # tests/suites/vps.nix asserts the kept path reaches the backend from
      # off-tailnet.
      #
      # Allowed sources: tailnet (admin access; headscale extra_records maps
      # auth.idanreed.com to the VPS tailnet IP — operator step after first
      # deploy, until then ssh -L 9000) and loopback.
      @restricted {
        path /if/admin* /api/v3/*
        not path /api/v3/flows/executor/* /api/v3/root/*
        not remote_ip 100.64.0.0/10 127.0.0.0/8 ::1
      }
      respond @restricted "restricted to tailnet" 403

      # Authentik's HTTP listener; 9443 (self-signed) is not published —
      # this is the only TLS path in.
      reverse_proxy 127.0.0.1:9000
    '';
  };

  # Caddy failure takes HTTPS for headscale AND authentik with it, plus the
  # DERP relay at /derp; established WireGuard sessions survive (which is why
  # the notifier can still reach ntfy), but nothing new can register. See
  # notify-failure@ in ../configuration.nix for the delivery limits; the
  # backstop is the Gatus probe pair over the public internet.
  #
  # No startLimit* override needed, read off the built unit: the nixpkgs
  # caddy module ships StartLimitIntervalSec=14400/StartLimitBurst=10 with
  # Restart=on-failure/RestartSec=5s, so ten rapid failures reach the limit
  # in ~50s and the unit genuinely enters `failed` (the state OnFailure keys
  # on). It also sets RestartPreventExitStatus=1, so an unparseable Caddyfile
  # fails on the first try instead of looping.
  systemd.services.caddy.onFailure = [ "notify-failure@%n.service" ];
}
