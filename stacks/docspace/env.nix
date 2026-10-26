# Values built at activation from other secrets, never stored twice — see
# nixos/modules/stack-env.nix. `secret` reads this stack's secrets.sops.json,
# `shared` reads secrets/shared.sops.json.
{ secret, ... }:
{
  # DocSpace and the Document Server must sign with one key.
  JWT_SECRET = secret "DOCUMENT_SERVER_JWT_SECRET";
}
