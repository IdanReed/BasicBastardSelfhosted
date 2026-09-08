# The only sops-nix wiring on the desktop, so defaultSopsFile/keyFile live here
# rather than in a module that would otherwise be empty.
{ lib, ... }:

let
  # Single source of truth, shared with modules/home/ssh-identities.nix: an
  # identity added there gets its sops secret declared here automatically.
  identities = import ../../ssh-identities.nix;
in
{
  sops = {
    defaultSopsFile = ../../secrets.sops.yaml;
    age.keyFile = "/var/lib/sops-nix/sops_age_key.txt";

    # /run/secrets/ssh/<name>, idan-only — ssh refuses group/world-readable
    # identity files anyway.
    secrets = lib.mapAttrs' (
      name: _:
      lib.nameValuePair "ssh/${name}" {
        key = "ssh/${name}";
        owner = "idan";
        mode = "0600";
      }
    ) identities;
  };
}
