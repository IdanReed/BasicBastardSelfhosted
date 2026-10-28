# Rendered to /run/stack-env/media.cleanuparr.env and read ONLY by
# cleanuparr-init (nixos/modules/stack-env.nix): the Authentik client secret it
# writes into Cleanuparr's OIDC settings (Authentik reads the same shared
# value, cleanuparr-oidc.yaml) and the password it claims the first-run
# account with and signs in with afterwards.
{ shared, ... }:
{
  CLEANUPARR_OIDC_CLIENT_SECRET = shared "CLEANUPARR_OIDC_CLIENT_SECRET";
  # Idan's login.
  CLEANUPARR_ADMIN_PASSWORD = shared "IDAN_INITIAL_PASSWORD";
}
