# Rendered to /run/stack-env/media.cleanuparr.env and read ONLY by
# cleanuparr-init (nixos/modules/stack-env.nix): the Authentik client secret it
# writes into Cleanuparr's OIDC settings (Authentik reads the same shared
# value, cleanuparr-oidc.yaml), the password it claims the first-run account
# with and signs in with afterwards, and the credentials of the connections it
# declares — the Radarr/Sonarr API keys and qBittorrent's WebUI login.
{ secret, shared, ... }:
{
  CLEANUPARR_OIDC_CLIENT_SECRET = shared "CLEANUPARR_OIDC_CLIENT_SECRET";
  # Idan's login.
  CLEANUPARR_ADMIN_PASSWORD = shared "IDAN_INITIAL_PASSWORD";
  RADARR__AUTH__APIKEY = secret "RADARR__AUTH__APIKEY";
  SONARR__AUTH__APIKEY = secret "SONARR__AUTH__APIKEY";
  QBIT_WEBUI_USER = secret "QBIT_WEBUI_USER";
  # Idan's login, as in env.nix.
  QBIT_WEBUI_PASSWORD = shared "IDAN_INITIAL_PASSWORD";
}
