# Values built at activation from other secrets, never stored twice — see
# nixos/modules/stack-env.nix. `shared` reads secrets/shared.sops.json.
{ shared, ... }:
{
  # The outpost's API token. Authentik reads the same value (the blueprint
  # pins the token's key with !Env LDAP_OUTPOST_TOKEN), so the two cannot drift.
  AUTHENTIK_TOKEN = shared "LDAP_OUTPOST_TOKEN";
}
