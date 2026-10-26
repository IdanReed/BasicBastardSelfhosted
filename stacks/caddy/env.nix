# Values built at activation from other secrets, never stored twice — see
# nixos/modules/stack-env.nix. `secret` reads this stack's secrets.sops.json,
# `shared` reads secrets/shared.sops.json.
{ shared, ... }:
{
  # The VPS log shipper presents the same token.
  VLOGS_INGEST_TOKEN = shared "VLOGS_INGEST_TOKEN";
}
