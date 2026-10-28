# Rendered to /run/stack-env/media.jellyfin-ldap.env and read ONLY by
# jellyfin-init (nixos/modules/stack-env.nix), which writes it into the LDAP
# plugin's configuration: the bind account's password, the same shared value
# Authentik sets on the account (jellyfin-ldap.yaml). The other media
# containers have no use for it.
{ shared, ... }:
{
  JELLYFIN_LDAP_BIND_PASSWORD = shared "JELLYFIN_LDAP_BIND_PASSWORD";
}
