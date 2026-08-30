# Desktop sops-nix wiring + SSH identity private keys. This module replaces
# the former modules/nixos/sops.nix stub (which sat commented out waiting for
# a secrets file that now exists) — it is the only sops-nix wiring on the
# desktop, so defaultSopsFile/keyFile live here rather than in a separate
# module that would otherwise be empty.
{ lib, ... }:

let
  # Single source of truth: modules/home/ssh-identities.nix consumes the same
  # file, so an identity added there gets its sops secret declared here
  # automatically — no second list to keep in sync.
  identities = import ../../ssh-identities.nix;
in
{
  sops = {
    defaultSopsFile = ../../secrets.sops.yaml;
    age.keyFile = "/var/lib/sops-nix/sops_age_key.txt";

    # One secret per identity: /run/secrets/ssh/<name>, readable only by idan
    # (ssh refuses group/world-readable identity files anyway).
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
