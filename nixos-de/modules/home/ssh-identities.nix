# SSH client config GENERATED from ../../ssh-identities.nix — one Host block
# per identity, keyed to the sops-decrypted private key. Adding an identity
# there is all it takes; nothing is listed here by hand.
#
# WHY programs.ssh.settings and not matchBlocks: the pinned home-manager
# (2026-06) deprecates matchBlocks as a compatibility alias of settings and
# warns on every eval/hms; settings takes upstream ssh_config directive
# names, which is also why identity extraOptions use upstream names.
{ lib, ... }:

let
  identities = import ../../ssh-identities.nix;
in
{
  programs.ssh = {
    enable = true;

    # WHY false: true only injects a "*" block of ssh's own defaults plus a
    # removal warning. We want no global defaults — every host we care about
    # has an explicit block below.
    enableDefaultConfig = false;

    # The attribute name becomes the Host pattern. It carries BOTH the short
    # alias (`ssh github`) and the real host, so plain `git@github.com` /
    # `ssh idan@10.0.0.3` pick up the identity too — the alias alone would
    # silently skip the key for those.
    settings = lib.mapAttrs' (
      name: identity:
      lib.nameValuePair "${name} ${identity.host}" (
        {
          HostName = identity.host;
          User = identity.user;
          # WHY hardcoded /run/secrets path: home-manager is standalone here
          # (`hms` cannot see the NixOS config, so no config.sops reference
          # is possible), but sops-nix's defaultSymlinkPath makes
          # /run/secrets deterministic — the NixOS module's "ssh/<name>"
          # secrets always land exactly here.
          IdentityFile = "/run/secrets/ssh/${name}";
          IdentitiesOnly = true;
        }
        // lib.optionalAttrs (identity ? port) { Port = identity.port; }
        // (identity.extraOptions or { })
      )
    ) identities;
  };
}
