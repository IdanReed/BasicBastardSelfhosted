# Work VPN + RDP — the OS half, which is nothing but sops secrets. The tunnel
# needs no system wiring at all (see modules/home/work-vpn.nix); these five
# parameters are secrets by exposure, not capability — collectively a map of an
# employer's network, and this repo is public.
#
# The password is deliberately NOT here: the gateway demands a second factor
# anyway, so storing it buys nothing and costs a corporate credential at rest.
{ lib, ... }:

let
  # Mirrors the workvpn: block in secrets.sops.yaml one-to-one.
  params = [
    "gateway" # AnyConnect gateway FQDN
    "vpn_user" # gateway login — often the email/UPN
    "authgroup" # AnyConnect tunnel group ("connection profile")
    "rdp_host" # Windows box, as named INSIDE the tunnel
    # Separate from vpn_user: RDP wants a bare sAMAccountName + domain, or a UPN
    # with NO domain — never both, and the gateway usually wants the other form.
    "rdp_user"
    "rdp_domain" # AD short/NetBIOS domain; empty when rdp_user is a UPN
  ];
in
{
  # /run/secrets/workvpn/<param>, idan-only — the wrappers are unprivileged.
  sops.secrets = lib.genAttrs (map (p: "workvpn/${p}") params) (name: {
    key = name;
    owner = "idan";
    mode = "0400";
  });
}
