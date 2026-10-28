# Values built at activation from other secrets, never stored twice — see
# nixos/modules/stack-env.nix. `secret` reads this stack's secrets.sops.json,
# `shared` reads secrets/shared.sops.json.
{ secret, shared, ... }:
{
  # Built from the one Postgres password.
  DATABASE_URL = "postgres://windmill:${secret "POSTGRES_PASSWORD"}@windmill_db:5432/windmill?sslmode=disable";

  # The client secret Authentik's windmill-oidc blueprint reads; windmill-init
  # writes it into the `oauths` instance setting.
  WINDMILL_OIDC_CLIENT_SECRET = shared "WINDMILL_OIDC_CLIENT_SECRET";

  # idan's one password, the same value Authentik sets; windmill-init creates
  # him as the password-login superadmin.
  IDAN_INITIAL_PASSWORD = shared "IDAN_INITIAL_PASSWORD";
}
