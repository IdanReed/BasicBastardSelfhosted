{ lib, ... }:

# Inbound SSH. Password auth is the point — this host is an SSH *client*
# everywhere else and the reason to reach it is ad-hoc, from a phone or laptop
# with no enrolled key. Two independent layers must both fail before a password
# prompt reaches the internet: the port is opened on the wired LAN NIC only, and
# PasswordAuthentication is off except in the LAN Match block.
{
  services.openssh = {
    enable = true;

    # openFirewall opens the port on EVERY interface, docker bridges included.
    openFirewall = false;

    settings = {
      PasswordAuthentication = false;
      # The other PAM-backed password path — leaving it on hands out exactly the
      # prompt the Match block withholds.
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };

    # extraConfig is cat'd after the generated settings, which is what a Match
    # block needs — every directive after `Match` is conditional.
    extraConfig = ''
      Match Address 10.0.0.0/24
        PasswordAuthentication yes
    '';
  };

  # settings.PasswordAuthentication = false makes the NixOS module hardcode
  # security.pam.services.sshd.unixAuth = false, so PAM rejects the password
  # sshd was willing to accept. Plain assignment inside mkIf — mkForce is the
  # only override. Safe: PAM never sees an attempt sshd did not offer.
  security.pam.services.sshd.unixAuth = lib.mkForce true;

  # Named interface rather than allowedTCPPorts: a rename fails CLOSED. Note
  # tailscale0 is a trustedInterface (tailscale.nix), so tailnet peers do reach
  # :22 — outside the Match block, and no authorized_keys exists yet.
  networking.firewall.interfaces.enp12s0.allowedTCPPorts = [ 22 ];
}
