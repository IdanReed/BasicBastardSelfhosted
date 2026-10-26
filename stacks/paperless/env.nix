# Values built at activation from other secrets, never stored twice — see
# nixos/modules/stack-env.nix. `secret` reads this stack's secrets.sops.json,
# `shared` reads secrets/shared.sops.json.
{ secret, shared, ... }:
{
  # The Authentik client's secret, one value in secrets/shared.sops.json.
  PAPERLESS_OIDC_CLIENT_SECRET = shared "PAPERLESS_OIDC_CLIENT_SECRET";
  # The app side of the Postgres password.
  PAPERLESS_DBPASS = secret "POSTGRES_PASSWORD";
}
