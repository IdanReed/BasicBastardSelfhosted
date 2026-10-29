{ config, pkgs, lib, ... }:

# Headscale coordination server — native systemd, not a container: core
# network infrastructure must boot without depending on the tailnet (or the
# container runtime) it underpins. TLS is Caddy's job; see modules/caddy.nix
# for why :443 could not be shared.

{
  # Shared with the Authentik blueprint that provisions the matching provider.
  # restartUnits matters: sops-nix renders to a stable path, so a rotation
  # leaves the unit byte-identical and headscale would keep the old value.
  sops.secrets.HEADSCALE_OIDC_CLIENT_SECRET = {
    owner = config.services.headscale.user;
    group = config.services.headscale.group;
    mode = "0400";
    restartUnits = [ "headscale.service" ];
  };

  services.headscale = {
    enable = true;

    # Loopback only — Caddy is the sole public listener.
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
        # Keeps headscale bootable when Authentik is down: existing nodes stay
        # connected and `headscale preauthkeys create` still works as
        # break-glass.
        only_start_if_oidc_is_available = false;
        issuer = "https://auth.idanreed.com/application/o/headscale/";
        client_id = "headscale";
        client_secret_path = config.sops.secrets.HEADSCALE_OIDC_CLIENT_SECRET.path;
        scope = [ "openid" "profile" "email" ];
        extra_params.domain_hint = "idanreed.com";
      };

      node = {
        # No node-key expiry, for OIDC and auth-key nodes alike. An expiring
        # node dies with no warning, and every channel that would report it
        # lives on the tailnet that just disappeared. Revocation stays an
        # explicit `headscale nodes expire|delete`, backed by the default-deny
        # ACLs in ../policy.hujson. Headscale refuses to start with the old
        # oidc.expiry key set.
        expiry = "0";

        # NOT node expiry despite the name: only garbage-collects EPHEMERAL
        # nodes, and nothing here registers ephemerally. The nixpkgs module
        # still renders the deprecated top-level
        # ephemeral_node_inactivity_timeout at its own default; this key wins.
        ephemeral.inactivity_timeout = "30m";
      };

      prefixes = {
        v4 = "100.64.0.0/10";
        v6 = "fd7a:115c:a1e0::/48";
      };

      dns = {
        magic_dns = true;
        # Must differ from the server_url hostname. Nodes get
        # <hostname>.tailnet.idanreed.com.
        base_domain = "tailnet.idanreed.com";
        search_domains = [ "tailnet.idanreed.com" ];

        # dns.nameservers.global is deliberately unset — it once pointed at a
        # never-deployed CoreDNS and broke DNS on every client. Clients keep
        # their own resolvers; *.svc.idanreed.com is a public A record into
        # CGNAT space, routable only inside the tailnet.
        #
        # Must be explicit: headscale defaults this to true, and true without
        # nameservers.global is a fatal config error (headscale crash-loops).
        override_local_dns = false;
      };

      derp = {
        # Empty on purpose: the nixpkgs default fetches Tailscale's public DERP
        # map, routing relayed traffic through Tailscale-operated servers.
        urls = [ ];

        server = {
          enabled = true;
          region_id = 999;
          region_code = "headscale";
          region_name = "Headscale Embedded DERP";
          stun_listen_addr = "0.0.0.0:3478";
        };
      };

      # Default-deny ACLs; ../policy.hujson has the rules and tagging workflow.
      policy = {
        mode = "file";
        path = ../policy.hujson;
      };

      log = {
        level = "info";
        format = "text";
      };

      disable_check_updates = true;
    };
  };

  systemd.services.headscale = {
    onFailure = [ "notify-failure@%n.service" ];

    # Headscale probes OIDC discovery exactly once at startup and on failure
    # falls back to CLI-auth for its whole lifetime, silently. On first boot
    # that probe races Caddy's initial cert issuance and loses. Bounded, so a
    # genuinely down Authentik still lets headscale start in break-glass mode;
    # the worst case must fit inside TimeoutStartSec below.
    preStart = ''
      for i in $(seq 1 30); do
        ${pkgs.curl}/bin/curl -sf --max-time 2 \
          https://auth.idanreed.com/application/o/headscale/.well-known/openid-configuration \
          -o /dev/null && exit 0
        sleep 2
      done
      echo "OIDC discovery still unreachable after ~120s — starting anyway (CLI-auth fallback)"
    '';
    serviceConfig.TimeoutStartSec = 300;

    # Required for OnFailure to mean anything: the module ships
    # Restart=always/RestartSec=5s under the default 5 starts / 10 SECONDS, so
    # the unit never reaches `failed`. Giving up is correct — every way
    # headscale fails to start is permanent until something changes, and
    # stopping the loop also stops it rewriting the journal mid-diagnosis.
    startLimitIntervalSec = 3600;
    startLimitBurst = 10;
  };
}
