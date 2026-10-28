# Values built at activation from other secrets, never stored twice — see
# nixos/modules/stack-env.nix. `secret` reads this stack's secrets.sops.json,
# `shared` reads secrets/shared.sops.json.
{ shared, ... }:
{
  # Idan's login (QBIT_WEBUI_PASSWORD_PBKDF2 is its stored hash).
  QBIT_WEBUI_PASSWORD = shared "IDAN_INITIAL_PASSWORD";
  # Idan's login.
  JELLYFIN_ADMIN_PASSWORD = shared "IDAN_INITIAL_PASSWORD";
}
