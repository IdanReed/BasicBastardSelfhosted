# SSH client config GENERATED from ../../ssh-identities.nix — nothing is listed
# here by hand. `settings`, not `matchBlocks`: the latter is a deprecated alias
# in the pinned home-manager and warns on every eval.
{ lib, ... }:

let
  identities = import ../../ssh-identities.nix;
in
{
  programs.ssh = {
    enable = true;

    # true only injects a "*" block of ssh's own defaults plus a removal warning.
    enableDefaultConfig = false;

    # The attribute name becomes the Host pattern, carrying BOTH the alias and
    # the real host, so plain `git@github.com` picks up the identity too.
    settings = lib.mapAttrs' (
      name: identity:
      lib.nameValuePair (lib.concatStringsSep " " ([ name ] ++ (identity.aliases or [ ]) ++ [ identity.host ])) (
        {
          HostName = identity.host;
          User = identity.user;
          # Hardcoded because home-manager is standalone here (`hms` cannot see
          # config.sops); sops-nix's defaultSymlinkPath makes /run/secrets
          # deterministic.
          IdentityFile = "/run/secrets/ssh/${name}";
          IdentitiesOnly = true;
        }
        // lib.optionalAttrs (identity ? port) { Port = identity.port; }
        // (identity.extraOptions or { })
      )
    ) identities;
  };
}
