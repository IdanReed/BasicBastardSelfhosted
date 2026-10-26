# Values built at activation from other secrets, never stored twice — see
# nixos/modules/stack-env.nix. `secret` reads this stack's secrets.sops.json,
# `shared` reads secrets/shared.sops.json.
{ secret, shared, ... }:
{
  # Built from the one Postgres password.
  DATABASE_URL = "postgres://windmill:${secret "POSTGRES_PASSWORD"}@windmill_db:5432/windmill?sslmode=disable";

  # The same per-user passwords Authentik sets; windmill-init creates the users.
  IDAN_INITIAL_PASSWORD = shared "IDAN_INITIAL_PASSWORD";
  ALONDRA_INITIAL_PASSWORD = shared "ALONDRA_INITIAL_PASSWORD";
  CALE_INITIAL_PASSWORD = shared "CALE_INITIAL_PASSWORD";
  ZACH_INITIAL_PASSWORD = shared "ZACH_INITIAL_PASSWORD";
  RYLAN_INITIAL_PASSWORD = shared "RYLAN_INITIAL_PASSWORD";
  CAMERON_INITIAL_PASSWORD = shared "CAMERON_INITIAL_PASSWORD";
  JUSTIN_INITIAL_PASSWORD = shared "JUSTIN_INITIAL_PASSWORD";
}
