# Work VPN + RDP — the OS half, which is nothing but sops secrets.
#
# The tunnel itself needs NO system wiring at all: no networking option, no
# systemd unit, no capability, no tun device. openconnect runs --script-tun
# entirely as idan and terminates the tunnel in a userspace TCP stack (see
# modules/home/work-vpn.nix for the why). Everything this module does is keep
# five connection parameters out of a public repo.
#
# They are secrets by exposure, not by capability — none of them grants
# access on its own, but a corporate gateway hostname, an AnyConnect tunnel
# group, a login name and a workstation FQDN are collectively a map of an
# employer's network, and this repo is on GitHub.
#
# The password is deliberately NOT here. The gateway wants a second factor
# every time anyway, so a stored password buys nothing and costs a corporate
# credential at rest; openconnect prompts for both on each connect.
{ lib, ... }:

let
  # Mirrors the workvpn: block in secrets.sops.yaml one-to-one. Adding a
  # parameter is one entry here plus one key there.
  # WHY vpn_user and rdp_user are separate keys: the gateway and the Windows
  # box routinely want different name forms. AnyConnect is commonly driven by
  # a UPN/email (ireed@corp.example.com), while RDP wants either a bare
  # sAMAccountName paired with a domain or a UPN with NO domain — never both.
  # A single reused value silently produces the broken third combination.
  params = [
    "gateway" # AnyConnect gateway FQDN
    "vpn_user" # gateway login — often the email/UPN
    "authgroup" # AnyConnect tunnel group ("connection profile")
    "rdp_host" # Windows box, as named INSIDE the tunnel
    "rdp_user" # RDP login — bare name, or a UPN (then leave rdp_domain empty)
    "rdp_domain" # AD short/NetBIOS domain; empty when rdp_user is a UPN
  ];
in
{
  # /run/secrets/workvpn/<param>, readable only by idan — the wrappers are
  # unprivileged, so root-only would defeat the point.
  sops.secrets = lib.genAttrs (map (p: "workvpn/${p}") params) (name: {
    key = name;
    owner = "idan";
    mode = "0400";
  });
}
