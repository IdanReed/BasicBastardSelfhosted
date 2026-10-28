# Values built at activation from other secrets, never stored twice — see
# nixos/modules/stack-env.nix. `secret` reads this stack's secrets.sops.json,
# `shared` reads secrets/shared.sops.json.
{ secret, shared, ... }:
{
  # The app side of the Postgres password.
  DJANGO_DB_PASSWORD = secret "POSTGRES_PASSWORD";

  # The client secret Authentik's wger-oidc blueprint reads; wger_init writes
  # it into the allauth SocialApp row.
  WGER_OIDC_CLIENT_SECRET = shared "WGER_OIDC_CLIENT_SECRET";
}
