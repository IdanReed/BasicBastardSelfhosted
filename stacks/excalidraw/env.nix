# Values built at activation from other secrets, never stored twice — see
# nixos/modules/stack-env.nix. `secret` reads this stack's secrets.sops.json,
# `shared` reads secrets/shared.sops.json.
{ secret, shared, ... }:
{
  # The Authentik client's secret, one value in secrets/shared.sops.json.
  OIDC_CLIENT_SECRET = shared "EXCALIDRAW_OIDC_CLIENT_SECRET";
  # Keyv's connection string, built from the one Postgres password.
  STORAGE_URI = "postgres://excalidraw:${secret "POSTGRES_PASSWORD"}@excalidraw_db:5432/excalidraw_storage";
}
