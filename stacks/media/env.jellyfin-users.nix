# Rendered to /run/stack-env/media.jellyfin-users.env and read ONLY by
# jellyfin-init (nixos/modules/stack-env.nix): each user's one password — the
# value Authentik sets for them — must not reach the other media containers
# through media.env. jellyfin-init seeds a Jellyfin account per user with it.
{ shared, ... }:
{
  ALONDRA_INITIAL_PASSWORD = shared "ALONDRA_INITIAL_PASSWORD";
  CALE_INITIAL_PASSWORD = shared "CALE_INITIAL_PASSWORD";
  ZACH_INITIAL_PASSWORD = shared "ZACH_INITIAL_PASSWORD";
  RYLAN_INITIAL_PASSWORD = shared "RYLAN_INITIAL_PASSWORD";
  CAMERON_INITIAL_PASSWORD = shared "CAMERON_INITIAL_PASSWORD";
  JUSTIN_INITIAL_PASSWORD = shared "JUSTIN_INITIAL_PASSWORD";
}
