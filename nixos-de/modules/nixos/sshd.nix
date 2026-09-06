{ lib, ... }:

# Inbound SSH on the desktop. There was none before this module — no sshd
# unit, nothing bound to :22 — so this is the first way in, not a loosening
# of an existing posture.
#
# Password auth is the point of it: this host is an SSH *client* everywhere
# else (ssh-identities.nix hands it keys for github/proxmox/vps/...), nothing
# holds a key that authorises the reverse direction, and the whole reason to
# reach the desktop is ad-hoc — from a phone or a laptop that has no enrolled
# key. Restricting that to the LAN is the compensating control, applied in two
# independent layers that both have to fail before a password prompt is
# offered to the internet:
#
#   1. Reachability — port 22 is opened on the wired LAN NIC only.
#   2. Authentication — PasswordAuthentication is off globally and turned back
#      on only for the LAN subnet, so a source that somehow reaches the port
#      from elsewhere is still offered no method it can satisfy.
{
  services.openssh = {
    enable = true;

    # openFirewall opens the port on EVERY interface, docker bridges and all.
    # The interface-scoped rule at the bottom replaces it.
    openFirewall = false;

    settings = {
      # Off globally; the Match block below is the only place it is true.
      PasswordAuthentication = false;
      # The other PAM-backed password path — leaving it on would hand out
      # exactly the prompt the Match block is there to withhold.
      KbdInteractiveAuthentication = false;
      # Tighter than the NixOS default of prohibit-password: no key authorises
      # root here either, so there is nothing to keep the door open for.
      PermitRootLogin = "no";
    };

    # sshd.nix builds sshd_config by cat'ing the generated settings and THEN
    # extraConfig, which is what a Match block requires — every directive
    # after `Match` is conditional, so it has to be last in the file.
    extraConfig = ''
      Match Address 10.0.0.0/24
        PasswordAuthentication yes
    '';
  };

  # The gotcha that makes the Match block actually work. With
  # settings.PasswordAuthentication = false the NixOS module hardcodes
  # `security.pam.services.sshd.unixAuth = false`, and PAM then rejects the
  # password that sshd was willing to accept — a LAN login fails with a
  # generic "Permission denied" and nothing in the config looks wrong. It is a
  # plain assignment inside a mkIf, not a mkDefault, so mkForce is the only
  # way to override it. Safe: PAM never sees the attempt unless sshd offered
  # the password method first, which off-LAN it does not.
  security.pam.services.sshd.unixAuth = lib.mkForce true;

  # Layer 1. Named interface rather than a blanket allowedTCPPorts: a rename
  # fails CLOSED (port open on nothing) instead of open on everything.
  #
  # tailscale0 is a trustedInterface (tailscale.nix), so tailnet peers do
  # reach the port — deliberately. They fall outside the Match block and no
  # authorized_keys file exists yet, so today that reachability grants
  # nothing; the day a key is added, tailnet becomes key-only access without
  # touching this file.
  networking.firewall.interfaces.enp12s0.allowedTCPPorts = [ 22 ];
}
