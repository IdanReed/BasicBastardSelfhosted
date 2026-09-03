{ config, pkgs, lib, ... }:

# Headscale coordination server — native systemd, not a container: core
# network infrastructure must come up on boot without depending on the
# tailnet (or the container runtime) it underpins.
#
# nixos-25.11 ships headscale 0.27.x; vs the old 0.23 config:
#   - oidc.strip_email_domain removed upstream (users keyed by iss+sub now)
#   - dns.base_domain may not equal the server_url hostname
#
# TLS is NOT handled here: headscale is loopback-only and Caddy terminates
# for both this and Authentik — see modules/caddy.nix for why :443 could not
# be shared.

{
  # OIDC client secret, shared with the Authentik blueprint that provisions
  # the matching provider. restartUnits matters: sops-nix renders to a
  # *stable* path, so a rotation leaves the unit byte-identical — without
  # this, Authentik's blueprint picks up the new value, Headscale keeps the
  # old one, and OIDC breaks until someone notices.
  sops.secrets.HEADSCALE_OIDC_CLIENT_SECRET = {
    owner = config.services.headscale.user;
    group = config.services.headscale.group;
    mode = "0400";
    restartUnits = [ "headscale.service" ];
  };

  services.headscale = {
    enable = true;

    # Loopback only — Caddy is the sole public listener. Off :443 the nixpkgs
    # module no longer grants CAP_NET_BIND_SERVICE; fine, nothing here binds
    # a privileged port any more.
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

        # Node key expiry is a DECISION, not an inherited default. headscale
        # 0.27.1 has exactly ONE expiry knob for ordinary nodes — this one.
        # Verified in the tagged source:
        #   - hscontrol/types/config.go:326  viper.SetDefault("oidc.expiry", "180d")
        #     (defaultOIDCExpiryTime = 180 * 24h at config.go:27; literal "0"
        #     special-cased at config.go:958-971 = no expiry)
        #   - hscontrol/oidc.go:111-116  stamps every OIDC-registered node
        #     with now + that duration
        #   - hscontrol/auth.go:316-318, 446-448  preauth-key nodes expire
        #     only if the client sent a non-zero expiry; no headscale default
        # So the shipped default split the fleet: preauth-key nodes never
        # expire, OIDC-enrolled nodes die at day 180 — silently by
        # construction (auth.go:158-166 returns NodeKeyExpired, no warning,
        # no pre-expiry signal), and every channel that would report it
        # (ntfy, the OnFailure notifiers, Gatus's service probes) lives ON
        # the tailnet that just disappeared.
        #
        # "0" rather than a long finite value: that is the same silent
        # failure with a longer fuse, still inconsistent across enrolment
        # paths. Revocation stays as an explicit operator action —
        #   headscale nodes expire --identifier <id>
        #   headscale nodes delete --identifier <id>
        # — backed by the default-deny ACLs in ../policy.hujson.
        #
        # ⚠ REVISIT ON 0.28: `oidc.expiry` is REMOVED, replaced by
        # `node.expiry`, which ALSO applies to auth-key-registered nodes
        # (tagged exempt). Set `node.expiry = "0"` as part of that upgrade,
        # or this exact failure returns — on MORE nodes.
        expiry = "0";
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

        # dns.nameservers.global deliberately NOT set — it once pointed at a
        # never-deployed CoreDNS, handing every client a dead resolver and
        # breaking ALL their DNS. Clients keep their own resolvers;
        # *.svc.idanreed.com is a public Cloudflare A record into CGNAT space
        # (only routable inside the tailnet, so not an exposure).
        #
        # Must be explicit: 0.27 defaults this to true, and true with no
        # nameservers.global is a FATAL config error — headscale crash-loops
        # with no control plane. Caught by tests/suites/vps.nix.
        override_local_dns = false;
      };

      # Embedded DERP relay for NAT traversal; proxied by Caddy on /derp.
      derp = {
        # Empty on purpose: the nixpkgs default fetches Tailscale's public
        # DERP map, routing relayed traffic through Tailscale-operated
        # servers.
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

      # NOT node expiry, despite the name: only garbage-collects EPHEMERAL
      # nodes, and nothing in this fleet registers ephemerally. Real expiry
      # is oidc.expiry above.
      ephemeral_node_inactivity_timeout = "30m";
    };
  };

  # A dead control plane takes the alert path with it, so it gets the
  # notifier even though delivery is best-effort — see notify-failure@ in
  # ../configuration.nix. Out-of-band backstop: the Gatus /health probe
  # (stacks/gatus/gatus.yaml) reaches this host over the PUBLIC internet.
  systemd.services.headscale = {
    onFailure = [ "notify-failure@%n.service" ];

    # Headscale probes the OIDC discovery URL exactly ONCE at startup and on
    # any failure silently falls back to CLI-auth for its whole lifetime
    # (only_start_if_oidc_is_available=false, kept deliberately — see the
    # design table). On first boot that probe races Caddy's initial
    # cert issuance for auth.idanreed.com and loses (hit live 2026-09-03:
    # "tls: internal error", every OIDC login degraded until a manual
    # restart). Wait for the discovery doc — but BOUNDED, so a genuinely
    # down Authentik still lets headscale start in break-glass mode.
    # Worst case must fit inside TimeoutStartSec below — a switch restarts
    # authentik alongside us, and its ~60s health-start window is the normal
    # case, not the exception (first switch: start-pre was killed at the
    # default timeout mid-wait).
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

    # Required for OnFailure to mean anything: the nixpkgs module ships
    # Restart=always/RestartSec=5s under the default limit of 5 starts / 10
    # SECONDS — at 5s apart at most 2 starts land in the window, so the unit
    # never enters `failed` and OnFailure never runs. Exactly the shape of
    # the override_local_dns crash-loop above, which said nothing.
    #
    # 10 starts/hour ≈ 50s of crash-looping before it gives up and alerts.
    # Giving up is correct: every way headscale fails to START is permanent
    # until a human or rebuild changes something, and stopping the loop also
    # stops it rewriting the journal mid-diagnosis.
    startLimitIntervalSec = 3600;
    startLimitBurst = 10;
  };
}
