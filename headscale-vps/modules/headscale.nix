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

        # Node key expiry is a DECISION here, not an inherited default.
        #
        # headscale 0.27.1 has exactly ONE expiry knob for ordinary nodes and
        # this is it. Verified in the tagged source, not from memory:
        #   - hscontrol/types/config.go:326  viper.SetDefault("oidc.expiry", "180d")
        #     (with defaultOIDCExpiryTime = 180 * 24h at config.go:27, and the
        #     literal string "0" special-cased at config.go:958-971 to mean
        #     "no expiry")
        #   - hscontrol/oidc.go:111-116  determineNodeExpiry() stamps every
        #     OIDC-registered node with now + that duration.
        #   - hscontrol/auth.go:316-318, 446-448  a node registered with a
        #     PREAUTH KEY gets an expiry only if the tailscale client itself
        #     sent a non-zero one; headscale applies no default of its own.
        # So the shipped default gave the fleet two different lifetimes
        # depending on how each node happened to be enrolled: preauth-key
        # nodes (this host and the services VM, via tailscale-autoconnect)
        # never expire, browser/OIDC-enrolled nodes die at day 180.
        #
        # The 180-day path is silent by construction. headscale emits no
        # warning, no notification and no pre-expiry signal — the node just
        # stops forwarding traffic (auth.go:158-166 returns NodeKeyExpired and
        # forces re-authentication). And every channel that would report it —
        # ntfy, the OnFailure notifiers on both hosts, Gatus's service probes —
        # lives ON the tailnet, i.e. inside exactly what disappears.
        #
        # "0" (no expiry) rather than a long finite value: a multi-year number
        # is the same silent failure with a longer fuse and nobody left who
        # remembers setting it, and it would still leave the two enrolment
        # paths inconsistent. Revocation is not given up — it becomes an
        # explicit, immediate operator action instead of a timer:
        #   headscale nodes expire --identifier <id>
        #   headscale nodes delete --identifier <id>
        # backed by the default-deny ACLs in ../policy.hujson.
        #
        # ⚠ REVISIT ON UPGRADE TO headscale 0.28: `oidc.expiry` is REMOVED
        # there and replaced by `node.expiry`, which — unlike this key —
        # ALSO applies to auth-key-registered nodes (tagged nodes exempt).
        # Setting `node.expiry = "0"` is part of that upgrade; skipping it
        # introduces the exact failure this line exists to prevent, on MORE
        # nodes than it ever applied to here.
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

        # dns.nameservers.global is deliberately NOT set. It previously pointed
        # at 100.64.0.1 for a CoreDNS instance that was never deployed, which
        # handed every client a single dead resolver and broke all DNS — not
        # just tailnet names. Clients now keep their own resolvers, and
        # *.svc.idanreed.com is a public Cloudflare A record pointing at the
        # services VM's tailnet IP (CGNAT space, only routable from inside the
        # tailnet, so publishing it is not an exposure).
        #
        # This must be set explicitly. headscale 0.27 defaults it to true, and
        # true with no nameservers.global is a FATAL config error:
        #   "dns.nameservers.global must be set when dns.override_local_dns is
        #    true"
        # so leaving it at the default made headscale refuse to start at all —
        # crash-looping, with no control plane. Caught by tests/suites/vps.nix.
        override_local_dns = false;
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

      # NOT a node-expiry setting, despite the name being the first thing that
      # turns up when looking for one: this only garbage-collects EPHEMERAL
      # nodes (registered with an ephemeral preauth key) after they go quiet.
      # Nothing in this fleet registers ephemerally. Real node expiry is
      # oidc.expiry above.
      ephemeral_node_inactivity_timeout = "30m";
    };
  };

  # A dead control plane is the one failure that takes the alert path with it,
  # so it gets the notifier even though delivery is best-effort — see the long
  # comment on notify-failure@ in ../configuration.nix. The out-of-band
  # backstop is the Gatus probe of https://headscale.idanreed.com/health in
  # stacks/gatus/gatus.yaml, which runs on the services VM and reaches this
  # host over the PUBLIC internet, so it survives the tailnet being down.
  systemd.services.headscale = {
    onFailure = [ "notify-failure@%n.service" ];

    # Required for the line above to mean anything. The nixpkgs module ships
    # Restart=always with RestartSec=5s and leaves the start-rate limit at the
    # systemd default of 5 starts / 10 SECONDS — 5s apart, at most 2 starts
    # ever land inside a 10s window, so the limit is unreachable, the unit
    # never enters `failed`, and OnFailure never runs. That is precisely the
    # shape of the crash-loop this module has already had once: the
    # override_local_dns fatal config error above left headscale restarting
    # forever with no control plane and nothing said so.
    #
    # 10 starts per hour: ~50s of crash-looping before the unit gives up and
    # alerts. Giving up is correct here — every way headscale fails to START
    # (bad config, unreadable db, an OIDC secret it cannot open) is permanent
    # until a human or a rebuild changes something, and 10 retries is already
    # far more than a transient deserves. It also stops the loop from
    # rewriting the journal while the operator is trying to read it.
    startLimitIntervalSec = 3600;
    startLimitBurst = 10;
  };
}
