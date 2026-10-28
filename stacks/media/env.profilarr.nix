# Rendered to /run/stack-env/media.profilarr.env and read ONLY by profilarr
# (nixos/modules/stack-env.nix): its Authentik client secret, under the name
# Profilarr reads, must not reach the other media containers through
# media.env. Authentik reads the same shared value (profilarr-oidc.yaml).
{ shared, ... }:
{
  OIDC_CLIENT_SECRET = shared "PROFILARR_OIDC_CLIENT_SECRET";
}
