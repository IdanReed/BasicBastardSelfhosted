{ config, pkgs, lib, ... }:

# Headscale coordination server.
#
# Replaces the former stacks/headscale/ compose stack. Headscale is core
# network infrastructure, so it is managed directly by systemd rather than
# through any container-sync mechanism: it must come up on boot without
# depending on the tailnet it provides.
#
# nixpkgs (nixos-25.11) ships headscale 0.27.x. Note the differences from the
# old 0.23 config.yaml this replaces:
#   - oidc.strip_email_domain was removed upstream (users are now identified by
#     the OIDC iss+sub claims, which are stable across email changes).
#   - dns.base_domain may not equal the server_url hostname, so MagicDNS names
#     live under a separate domain from the Headscale API endpoint.
#
# TLS is NOT handled here. Headscale listens on loopback and Caddy terminates
# HTTPS for both this and Authentik (modules/caddy.nix) — see the comment there
# for why sharing :443 was not possible.

{
  # OIDC client secret, shared with the Authentik blueprint that provisions the
  # matching provider. Readable only by the headscale service user.
  #
  # restartUnits matters: sops-nix renders secrets to a *stable* path, so
  # rotating this value leaves the systemd unit byte-identical and nothing
  # would restart. Without this, a rotated secret is picked up by Authentik's
  # blueprint but not by Headscale, and OIDC breaks until someone notices.
  sops.secrets.HEADSCALE_OIDC_CLIENT_SECRET = {
    owner = config.services.headscale.user;
    group = config.services.headscale.group;
    mode = "0400";
    restartUnits = [ "headscale.service" ];
  };

  services.headscale = {
    enable = true;

    # Loopback only — Caddy is the sole public listener. Note this drops below
    # 1024, so the nixpkgs module no longer grants CAP_NET_BIND_SERVICE; that
    # is fine because nothing here binds a privileged port any more.
    address = "127.0.0.1";
    port = 8080;

    settings = {
      server_url = "https://headscale.idanreed.com";
      metrics_listen_addr = "127.0.0.1:9090";

      database = {
        type = "sqlite";
        sqlite.path = "/var/lib/headscale/db.sqlite";
      };

      oidc = {
        # Keep Headscale bootable when Authentik is down: existing nodes stay
        # connected, and `headscale preauthkeys create --user idan` still works
        # from the CLI as a break-glass path. See README.
        only_start_if_oidc_is_available = false;
        issuer = "https://auth.idanreed.com/application/o/headscale/";
        client_id = "headscale";
        client_secret_path = config.sops.secrets.HEADSCALE_OIDC_CLIENT_SECRET.path;
        scope = [ "openid" "profile" "email" ];
        extra_params.domain_hint = "idanreed.com";
      };

      prefixes = {
        v4 = "100.64.0.0/10";
        v6 = "fd7a:115c:a1e0::/48";
      };

      dns = {
        magic_dns = true;
        # Must differ from the server_url hostname (headscale.idanreed.com).
        # Nodes get names like <hostname>.tailnet.idanreed.com.
        base_domain = "tailnet.idanreed.com";
        search_domains = [ "tailnet.idanreed.com" ];

        # dns.nameservers.global is deliberately NOT set. It previously pointed
        # at 100.64.0.1 for a CoreDNS instance that was never deployed, which
        # handed every client a single dead resolver and broke all DNS — not
        # just tailnet names. Clients now keep their own resolvers, and
        # *.svc.idanreed.com is a public Cloudflare A record pointing at the
        # services VM's tailnet IP (CGNAT space, only routable from inside the
        # tailnet, so publishing it is not an exposure).
      };

      # Embedded DERP relay for NAT traversal, so clients behind CGNAT can
      # still reach each other through this VPS. Proxied by Caddy on /derp.
      derp = {
        # Empty: do not fetch Tailscale's public DERP map. The nixpkgs default
        # is ["https://controlplane.tailscale.com/derpmap/default"], which
        # would route relayed traffic through Tailscale-operated servers.
        urls = [ ];

        server = {
          enabled = true;
          region_id = 999;
          region_code = "headscale";
          region_name = "Headscale Embedded DERP";
          stun_listen_addr = "0.0.0.0:3478";
        };
      };

      # Default-deny ACLs. See ../policy.hujson for the rules and the tagging
      # workflow. Behaviour-neutral until nodes are tagged.
      policy = {
        mode = "file";
        path = ../policy.hujson;
      };

      log = {
        level = "info";
        format = "text";
      };

      disable_check_updates = true;
      ephemeral_node_inactivity_timeout = "30m";
    };
  };
}
