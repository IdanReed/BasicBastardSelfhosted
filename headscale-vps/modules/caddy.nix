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

    virtualHosts."headscale.idanreed.com".extraConfig = ''
      # Headscale listens on loopback only (modules/headscale.nix).
      # reverse_proxy passes WebSocket upgrades through unchanged, which the
      # embedded DERP relay at /derp depends on. STUN is UDP/3478 and does not
      # pass through here at all.
      reverse_proxy 127.0.0.1:8080
    '';

    virtualHosts."auth.idanreed.com".extraConfig = ''
      # Authentik's HTTP listener. Its HTTPS listener (9443, self-signed) is
      # not published at all now — this is the only TLS path in.
      reverse_proxy 127.0.0.1:9000
    '';
  };
}
