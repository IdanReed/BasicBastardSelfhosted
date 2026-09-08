{ config, pkgs, ... }:

{
  # Static LAN IP
  # Declarative on purpose: cloud-init sets 10.0.0.3 only in the image build,
  # so every `nixos-rebuild switch` would otherwise hand the box back to DHCP.
  networking.useDHCP = false;
  networking.interfaces.ens18.ipv4.addresses = [
    { address = "10.0.0.3"; prefixLength = 24; }
  ];
  networking.defaultGateway = "10.0.0.1";
  networking.nameservers = [ "10.0.0.1" ];

  # Keeps the NIC named ens18 when a Proxmox machine-type change re-enumerates
  # the PCI bus. Both MACs: the one the live VM booted with and the one
  # flake.nix bakes into net0.
  systemd.network.links."10-lan" = {
    matchConfig.MACAddress = "a2:db:6f:f6:9f:d7 bc:24:11:5e:11:03";
    linkConfig.Name = "ens18";
  };

  # Caddy binds {$TAILNET_IP} with network_mode: host and crash-loops with
  # EADDRNOTAVAIL until tailscale0 has its address (finding #4).
  boot.kernel.sysctl."net.ipv4.ip_nonlocal_bind" = 1;

  # Tailscale
  services.tailscale.enable = true;

  # NOT RemainAfterExit: an active oneshot never deactivates, so
  # OnUnitInactiveSec below would never re-fire and the 180-day node-key
  # expiry would drop the node for good.
  systemd.services.tailscale-autoconnect = {
    description = "Automatic connection to Headscale";
    # tailscaled.service, not tailscale.service — systemd silently ignores
    # ordering on units that do not exist.
    after = [ "network-online.target" "tailscaled.service" ];
    wants = [ "network-online.target" "tailscaled.service" ];
    wantedBy = [ "multi-user.target" ];

    # Ntfy is loopback-local, so this still leaves the box when the tailnet is
    # what failed.
    onFailure = [ "notify-failure@%n.service" ];

    # Without these caps a timed-out cycle retries forever in `activating` and
    # never reaches `failed`, leaving OnFailure as dead code.
    unitConfig = {
      StartLimitIntervalSec = "30min";
      StartLimitBurst = 3;
    };

    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = "8min";
      Restart = "on-failure";
      RestartSec = "30s";
    };

    script = ''
      set -euo pipefail

      # Wait for a TERMINAL BackendState: an early sample reads a healthy node
      # mid-Starting as "not connected" and spends a single-use preauth key.
      state=""
      for _ in $(${pkgs.coreutils}/bin/seq 1 30); do
        state="$(${pkgs.tailscale}/bin/tailscale status -json 2>/dev/null \
                 | ${pkgs.jq}/bin/jq -r '.BackendState // empty' || true)"
        case "$state" in
          Running | NeedsLogin | NeedsMachineAuth | Stopped) break ;;
        esac
        sleep 2
      done
      [ -n "$state" ] || state=NoState

      if [ "$state" = "Running" ]; then
        expiry="$(${pkgs.tailscale}/bin/tailscale status -json \
          | ${pkgs.jq}/bin/jq -r '.Self.KeyExpiry // "none"' 2>/dev/null || echo unknown)"
        echo "Already connected to Headscale (node key expiry: $expiry)"
        exit 0
      fi

      # `tailscale up` cannot fix this and would spend a preauth key trying.
      if [ "$state" = "NeedsMachineAuth" ]; then
        echo "Node is registered but awaiting authorisation on Headscale." >&2
        echo "Approve it on the VPS (headscale nodes list / register); NOT re-running tailscale up." >&2
        exit 1
      fi

      echo "Not connected (BackendState=$state) - registering against Headscale"

      authkey="$(cat ${config.sops.secrets.TAILSCALE_AUTH_KEY.path})"
      case "$authkey" in changeme*)
        echo "TAILSCALE_AUTH_KEY is still a changeme_* template value — edit it with: sops nixos/secrets.sops.yaml" >&2
        exit 1 ;;
      esac

      # --login-server is required: without it the authkey goes to Tailscale's
      # SaaS control plane and a Headscale preauth key silently fails.
      ${pkgs.tailscale}/bin/tailscale up \
        --login-server=https://headscale.idanreed.com \
        --authkey "$authkey" \
        --hostname=services-vm \
        --accept-routes
    '';
  };

  # OnUnitInactiveSec, not OnCalendar: measured from the end of the last run,
  # so retries never stack.
  systemd.timers.tailscale-autoconnect = {
    description = "Re-register with Headscale before the node key expires";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "6h";
      OnUnitInactiveSec = "6h";
      RandomizedDelaySec = "30min";
      Unit = "tailscale-autoconnect.service";
    };
  };

  # Firewall
  # trustedInterfaces bypasses this list for tailnet traffic, so anything a
  # container publishes on 0.0.0.0 is tailnet-reachable: stacks bind published
  # ports to 127.0.0.1 and Caddy is the only way in.
  networking.firewall = {
    enable = true;
    trustedInterfaces = [ "tailscale0" ];
    allowedTCPPorts = [ 22 ];
  };
}
