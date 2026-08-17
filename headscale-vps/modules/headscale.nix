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
#   - ACME is driven by tls_letsencrypt_hostname; setting only acme_url and
#     acme_email (as the old config did) never actually enabled TLS.

{
  # OIDC client secret, shared with the Authentik blueprint that provisions the
  # matching provider. Readable only by the headscale service user.
  sops.secrets.HEADSCALE_OIDC_CLIENT_SECRET = {
    owner = config.services.headscale.user;
    group = config.services.headscale.group;
    mode = "0400";
  };

  services.headscale = {
    enable = true;

    # Bind the public API on 443. The nixpkgs module grants
    # CAP_NET_BIND_SERVICE automatically when port < 1024, so this still runs
    # as the unprivileged headscale user.
    address = "0.0.0.0";
    port = 443;

    settings = {
      server_url = "https://headscale.idanreed.com";
      metrics_listen_addr = "127.0.0.1:9090";

      # TLS via Let's Encrypt. HTTP-01 needs port 80 reachable, which the
      # firewall in configuration.nix allows.
      acme_email = "admin@idanreed.com";
      tls_letsencrypt_hostname = "headscale.idanreed.com";
      tls_letsencrypt_challenge_type = "HTTP-01";

      database = {
        type = "sqlite";
        sqlite.path = "/var/lib/headscale/db.sqlite";
      };

      oidc = {
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
        nameservers.global = [ "100.64.0.1" ]; # CoreDNS on this host's tailnet IP
        search_domains = [ "tailnet.idanreed.com" ];
      };

      # Embedded DERP relay for NAT traversal, so clients behind CGNAT can
      # still reach each other through this VPS.
      derp.server = {
        enabled = true;
        region_id = 999;
        region_code = "headscale";
        region_name = "Headscale Embedded DERP";
        stun_listen_addr = "0.0.0.0:3478";
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
