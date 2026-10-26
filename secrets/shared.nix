# Secrets more than one host consumes: the Authentik OIDC client secrets (the
# VPS registers the client, the services VM's app presents the secret), the
# per-user login passwords, and the VictoriaLogs ingest token. One encrypted
# value in shared.sops.json, read by both hosts — never a copy per host.
#
# Every key in the file becomes /run/secrets/<KEY> under its own name, so a
# consumer refers to it exactly as it would a host-local secret:
# config.sops.secrets.<KEY> / config.sops.placeholder.<KEY>. Key names are
# read from the encrypted file itself (sops leaves JSON keys plaintext).
{ config, lib, ... }:

let
  cfg = config.bbs.sharedSecrets;
  keys = lib.filter (k: k != "sops") (
    lib.attrNames (builtins.fromJSON (builtins.readFile cfg.file))
  );
in
{
  options.bbs.sharedSecrets.file = lib.mkOption {
    type = lib.types.path;
    default = ./shared.sops.json;
    description = ''
      Encrypted JSON holding the cross-host secrets. The test harness points
      this at tests/fixtures/shared.sops.json, encrypted to the throwaway key.
    '';
  };

  config.sops.secrets = lib.genAttrs keys (_: {
    sopsFile = cfg.file;
    format = "json";
  });
}
