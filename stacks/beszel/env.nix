# Values built at activation from other secrets, never stored twice — see
# nixos/modules/stack-env.nix. `secret` reads this stack's secrets.sops.json,
# `shared` reads secrets/shared.sops.json.
{ shared, ... }:
{
  # Idan's login, the same password Authentik sets.
  USER_PASSWORD = shared "IDAN_INITIAL_PASSWORD";

  # The client secret Authentik's beszel-oidc blueprint reads; beszel-role
  # writes it into the users collection's OAuth2 provider.
  BESZEL_OIDC_CLIENT_SECRET = shared "BESZEL_OIDC_CLIENT_SECRET";
}
