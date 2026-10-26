# Values built at activation from other secrets, never stored twice — see
# nixos/modules/stack-env.nix. `secret` reads this stack's secrets.sops.json,
# `shared` reads secrets/shared.sops.json.
{ secret, shared, ... }:
{
  # The Authentik client's secret, one value in secrets/shared.sops.json.
  BOOKSTACK_OIDC_CLIENT_SECRET = shared "BOOKSTACK_OIDC_CLIENT_SECRET";
  # The Authentik client's secret, one value in secrets/shared.sops.json.
  HOMEBOX_OIDC_CLIENT_SECRET = shared "HOMEBOX_OIDC_CLIENT_SECRET";
  # The Authentik client's secret, one value in secrets/shared.sops.json.
  KARAKEEP_OIDC_CLIENT_SECRET = shared "KARAKEEP_OIDC_CLIENT_SECRET";
  # The app side of the MariaDB password.
  DB_PASSWORD = secret "MARIADB_PASSWORD";
}
