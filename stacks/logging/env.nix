# Values built at activation from other secrets, never stored twice — see
# nixos/modules/stack-env.nix. `secret` reads this stack's secrets.sops.json,
# `shared` reads secrets/shared.sops.json.
{ shared, ... }:
{
  # The Authentik client's secret, one value in secrets/shared.sops.json.
  GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET = shared "GRAFANA_OIDC_CLIENT_SECRET";
}
