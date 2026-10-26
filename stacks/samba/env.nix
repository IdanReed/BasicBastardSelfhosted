# Values built at activation from other secrets, never stored twice — see
# nixos/modules/stack-env.nix. `secret` reads this stack's secrets.sops.json,
# `shared` reads secrets/shared.sops.json.
{ shared, ... }:
{
  # Each user's share password is their Authentik login password.
  SAMBA_IDAN_PASSWORD = shared "IDAN_INITIAL_PASSWORD";
  SAMBA_ALONDRA_PASSWORD = shared "ALONDRA_INITIAL_PASSWORD";
  SAMBA_CALE_PASSWORD = shared "CALE_INITIAL_PASSWORD";
  SAMBA_ZACH_PASSWORD = shared "ZACH_INITIAL_PASSWORD";
  SAMBA_RYLAN_PASSWORD = shared "RYLAN_INITIAL_PASSWORD";
  SAMBA_CAMERON_PASSWORD = shared "CAMERON_INITIAL_PASSWORD";
  SAMBA_JUSTIN_PASSWORD = shared "JUSTIN_INITIAL_PASSWORD";
}
