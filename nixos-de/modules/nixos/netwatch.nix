# netwatch: the desktop's own measurements of every network path to the
# fleet, so "it feels slow" has a cause in the journal. Three units:
#
#   netwatch-probe    (timer, 2 min) tailscale path + ping to services-vm and
#                     the VPS; DNS through MagicDNS, AdGuard and 1.1.1.1; every
#                     *.svc host through Caddy, split into connect / TLS /
#                     server time; Authentik's health check
#   netwatch-passive  (always on) sniffs this desktop's own DNS and tailnet TCP
#                     handshakes: every real lookup and connection, timed
#   netwatch-notify   (user, graphical session) a raised flag -> notification
#
# The VPS round trip is the thing to watch. A *.svc request should be one LAN
# hop to services-vm; the hosts the Caddyfile puts behind `import protected`
# add exactly one round trip to Authentik's outpost on the VPS. The probe
# reads that list from stacks/caddy/Caddyfile and flags any other host whose
# server time looks like a VPS round trip, any drift between the Caddyfile and
# what the outpost actually guards, and any *.svc name resolving away from
# services-vm.
#
# Read it with `netwatch report --since -6h`, or raw:
#   journalctl -t netwatch-probe -t netwatch-passive -o cat | jq
{
  config,
  pkgs,
  lib,
  ...
}:

let
  domain = "svc.idanreed.com";

  settings = {
    inherit domain;
    caddyfile = "${../../../stacks/caddy/Caddyfile}";
    services_peer = "services-vm";
    vps_peer = "headscale-vps";
    # The VPS firewall opens only STUN, so its link is DERP; that costs no
    # latency because the relay runs on the VPS itself.
    expect_direct = [ "services-vm" ];
    # Logged one record per new connection; everything else per minute.
    log_each_conn = [ "headscale-vps" ];
    auth_url = "https://auth.idanreed.com/-/health/live/";
    # The wildcard answers any name under it. Exclude it in AdGuard's query
    # log and statistics (Settings > General settings > Ignored domains):
    # ||netwatch.svc.idanreed.com^
    probe_name = "netwatch.${domain}";
    resolvers = {
      magicdns = "100.100.100.100";
      adguard = "10.0.0.1";
      control = "1.1.1.1";
    };
    burst_resolver = "adguard";
    burst_every = 5; # runs: a 50-query burst at 100 qps, the rate-limit check
    hosts_dns_every = 10; # runs: resolve every *.svc host by name
    ignore_hosts = [ ];
    state_dir = "/var/lib/netwatch-probe";
    thresholds = {
      dns_slow_ms = 250;
      dns_stall_ms = 1000;
      hop_floor_ms = 60;
      # A round trip to the VPS cannot take less than its RTT, so a host
      # below this cannot be waiting on the VPS.
      hop_fraction = 0.9; # of the VPS RTT
      fwd_auth_extra_ms = 250; # beyond one VPS RTT
      auth_slow_ms = 1500;
      direct_handshake_ms = 50;
      raise_after_runs = 2;
      aggregate_over = 5; # hosts with one problem -> one flag
      passive_window_s = 600;
      passive_raise_count = 3;
      notify_repeat_s = 1800;
    };
    tools = {
      curl = lib.getExe pkgs.curl;
      tailscale = "${config.services.tailscale.package}/bin/tailscale";
      tcpdump = lib.getExe pkgs.tcpdump;
      ip = "${pkgs.iproute2}/bin/ip";
      journalctl = "${config.systemd.package}/bin/journalctl";
      notify_send = "${pkgs.libnotify}/bin/notify-send";
    };
  };

  configFile = pkgs.writeText "netwatch.json" (builtins.toJSON settings);

  netwatch =
    pkgs.writers.writePython3Bin "netwatch"
      {
        flakeIgnore = [
          "E501"
          "W503"
          "W504"
        ];
      }
      (builtins.replaceStrings [ "@configFile@" ] [ "${configFile}" ] (builtins.readFile ./netwatch.py));

  hardening = {
    DynamicUser = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    NoNewPrivileges = true;
    RestrictAddressFamilies = [
      "AF_UNIX"
      "AF_INET"
      "AF_INET6"
      "AF_NETLINK"
    ];
  };
in
{
  environment.systemPackages = [ netwatch ];

  systemd.services.netwatch-probe = {
    description = "netwatch: probe tailnet paths, DNS and every *.svc host";
    after = [
      "network-online.target"
      "tailscaled.service"
    ];
    wants = [ "network-online.target" ];
    serviceConfig = hardening // {
      Type = "oneshot";
      ExecStart = "${netwatch}/bin/netwatch probe";
      StateDirectory = "netwatch-probe"; # flag state + one cookie jar per host
      SyslogIdentifier = "netwatch-probe";
      TimeoutStartSec = "110s";
    };
  };

  systemd.timers.netwatch-probe = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "2min";
      AccuracySec = "5s";
    };
  };

  systemd.services.netwatch-passive = {
    description = "netwatch: time this desktop's real DNS lookups and tailnet connections";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network-online.target"
      "tailscaled.service"
    ];
    wants = [ "network-online.target" ];
    serviceConfig = hardening // {
      ExecStart = "${netwatch}/bin/netwatch passive";
      # tcpdump runs as the dynamic user; capture needs these two only.
      AmbientCapabilities = [
        "CAP_NET_RAW"
        "CAP_NET_ADMIN"
      ];
      CapabilityBoundingSet = [
        "CAP_NET_RAW"
        "CAP_NET_ADMIN"
      ];
      RestrictAddressFamilies = hardening.RestrictAddressFamilies ++ [ "AF_PACKET" ];
      Restart = "always";
      RestartSec = "10s";
      SyslogIdentifier = "netwatch-passive";
    };
  };

  systemd.user.services.netwatch-notify = {
    description = "netwatch: notify on raised network flags";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    serviceConfig = {
      ExecStart = "${netwatch}/bin/netwatch notify";
      Restart = "always";
      RestartSec = "10s";
    };
  };
}
