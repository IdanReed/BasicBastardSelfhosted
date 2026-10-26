# Values built at activation from other secrets, never stored twice — see
# nixos/modules/stack-env.nix. `secret` reads this stack's secrets.sops.json,
# `shared` reads secrets/shared.sops.json.
{ secret, shared, ... }:
{
  # The Authentik client's secret, one value in secrets/shared.sops.json.
  DAWARICH_OIDC_CLIENT_SECRET = shared "DAWARICH_OIDC_CLIENT_SECRET";
  # The app side of the Postgres password.
  DATABASE_PASSWORD = secret "POSTGRES_PASSWORD";
}
