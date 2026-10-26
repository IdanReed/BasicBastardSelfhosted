# Values built at activation from other secrets, never stored twice — see
# nixos/modules/stack-env.nix. `secret` reads this stack's secrets.sops.json,
# `shared` reads secrets/shared.sops.json.
{ secret, shared, ... }:
{
  # The Authentik client's secret, one value in secrets/shared.sops.json.
  IMMICH_OIDC_CLIENT_SECRET = shared "IMMICH_OIDC_CLIENT_SECRET";
  # The database side of the app's DB_PASSWORD.
  POSTGRES_PASSWORD = secret "DB_PASSWORD";
}
