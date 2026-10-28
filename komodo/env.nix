# Values built at activation from other secrets, never stored twice — see
# nixos/modules/stack-env.nix. `secret` reads komodo/secrets.sops.json,
# `shared` reads secrets/shared.sops.json.
{ shared, ... }:
{
  # The Authentik client's secret, one value in secrets/shared.sops.json.
  KOMODO_OIDC_CLIENT_SECRET = shared "KOMODO_OIDC_CLIENT_SECRET";
}
