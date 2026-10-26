# Values built at activation from other secrets, never stored twice — see
# nixos/modules/stack-env.nix. `secret` reads this stack's secrets.sops.json,
# `shared` reads secrets/shared.sops.json.
{ secret, ... }:
{
  # The app side of the Postgres password.
  DJANGO_DB_PASSWORD = secret "POSTGRES_PASSWORD";
}
