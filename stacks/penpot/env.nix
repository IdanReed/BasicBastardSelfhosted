# Values built at activation from other secrets, never stored twice — see
# nixos/modules/stack-env.nix. `secret` reads this stack's secrets.sops.json,
# `shared` reads secrets/shared.sops.json.
{ secret, shared, ... }:
{
  # The Authentik client's secret, one value in secrets/shared.sops.json.
  PENPOT_OIDC_CLIENT_SECRET = shared "PENPOT_OIDC_CLIENT_SECRET";
  # The backend's copy of the one Postgres password.
  PENPOT_DATABASE_PASSWORD = secret "POSTGRES_PASSWORD";
}
