# Values built at activation from other secrets, never stored twice — see
# nixos/modules/stack-env.nix. `secret` reads this stack's secrets.sops.json,
# `shared` reads secrets/shared.sops.json.
{ shared, ... }:
{
  # Idan's login (QBIT_WEBUI_PASSWORD_PBKDF2 is its stored hash).
  QBIT_WEBUI_PASSWORD = shared "IDAN_INITIAL_PASSWORD";
  # Idan's login.
  JELLYFIN_ADMIN_PASSWORD = shared "IDAN_INITIAL_PASSWORD";
  # The Authentik client's secret, one value in secrets/shared.sops.json.
  JELLYFIN_OIDC_CLIENT_SECRET = shared "JELLYFIN_OIDC_CLIENT_SECRET";
}
