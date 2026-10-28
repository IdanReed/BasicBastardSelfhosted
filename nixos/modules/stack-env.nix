# Each compose stack's environment, rendered by sops-nix at activation.
#
# A stack's secrets live beside its compose file in secrets.sops.json (one
# stored value per key). An optional env.nix beside it adds values BUILT from
# other secrets — a DATABASE_URL around a password, an OIDC client secret from
# secrets/shared.sops.json — so no value is ever stored twice. Both become one
# sops template per stack.
#
# Containers cannot read the template where sops-nix writes it: /run/secrets
# is a symlink to /run/secrets.d/<generation>, the previous generation is
# deleted on every switch, and a bind mount resolves the symlink once. So
# stack-env-publish copies each rendered file into /run/stack-env, a plain
# directory Periphery mounts, re-run by sops-nix whenever a template changes.
#
# Compose reads /run/stack-env/<stack>.env twice: env_file (the containers'
# environment) and --env-file (`${VAR}` interpolation in compose.yaml itself).
#
# An env.<part>.nix beside env.nix (same { secret, shared } interface) renders
# to its own /run/stack-env/<stack>.<part>.env, which only the services that
# list it in env_file read: values one service needs and the rest of the stack
# must not see (media's jellyfin-init and the users' passwords). It is never an
# interpolation source.
{ config, lib, ... }:

let
  inherit (lib)
    attrNames
    concatStringsSep
    elem
    filter
    filterAttrs
    genAttrs
    intersectLists
    mapAttrs
    mapAttrsToList
    mkOption
    types
    ;

  cfg = config.bbs.stackEnv;
  root = ../..;
  stacksDir = root + "/stacks";

  # Every directory under stacks/ that carries a secrets.sops.json, plus the two
  # stacks the host runs itself (komodo/ and forgejo/: Komodo deploys from
  # Forgejo, so neither can be deployed by Komodo).
  discovered =
    mapAttrs (name: _: stacksDir + "/${name}") (
      filterAttrs (
        name: type: type == "directory" && builtins.pathExists (stacksDir + "/${name}/secrets.sops.json")
      ) (builtins.readDir stacksDir)
    )
    // {
      komodo = root + "/komodo";
      forgejo = root + "/forgejo";
    };

  stackDirs = cfg.stacks;

  keysOf =
    file: filter (k: k != "sops") (attrNames (builtins.fromJSON (builtins.readFile file)));

  secretName = stack: key: "stacks/${stack}/${key}";

  stackEnv =
    name: dir:
    let
      file = cfg.sourceFor name;
      keys = keysOf file;
      secret =
        k:
        if elem k keys then
          config.sops.placeholder.${secretName name k}
        else
          throw "stacks/${name}/env.nix: secret '${k}' is not a key of ${toString file}";
      shared =
        k:
        config.sops.placeholder.${k}
          or (throw "stacks/${name}/env.nix: '${k}' is not a key of the shared secrets file");
      envNix = dir + "/env.nix";
      derived = if builtins.pathExists envNix then import envNix { inherit secret shared; } else { };
      clash = intersectLists (attrNames derived) keys;
      vars =
        if clash != [ ] then
          throw "stacks/${name}: ${concatStringsSep ", " clash} is both stored in secrets.sops.json and built in env.nix"
        else
          genAttrs keys secret // derived;
      # Single-quoted: Compose interpolates env-file values, and a quoted value
      # is taken literally, so a `$` in a password or hash survives.
      render = v: concatStringsSep "\n" (mapAttrsToList (k: x: "${k}='${x}'") v) + "\n";
      partRe = "env\\.([a-z0-9-]+)\\.nix";
      partFiles = filterAttrs (
        f: t: t == "regular" && builtins.match partRe f != null
      ) (builtins.readDir dir);
    in
    {
      inherit file keys;
      content = render vars;
      parts = lib.mapAttrs' (
        f: _:
        lib.nameValuePair (builtins.head (builtins.match partRe f)) (
          render (import (dir + "/${f}") { inherit secret shared; })
        )
      ) partFiles;
    };

  envs = mapAttrs stackEnv stackDirs;
in
{
  options.bbs.stackEnv = {
    stacks = mkOption {
      type = types.attrsOf types.path;
      default = discovered;
      defaultText = lib.literalExpression "every stacks/<name> with a secrets.sops.json, plus komodo/ and forgejo/";
      description = ''
        Stack name -> its directory (where an optional env.nix lives). The test
        harness sets this from tests/fixtures/stacks/.
      '';
    };

    sourceFor = mkOption {
      type = types.functionTo types.path;
      default = name: stackDirs.${name} + "/secrets.sops.json";
      defaultText = lib.literalExpression ''name: <stack dir> + "/secrets.sops.json"'';
      description = ''
        The encrypted JSON a stack's environment is rendered from. The test
        harness points this at tests/fixtures/stacks/<name>.sops.json.
      '';
    };
  };

  config = {
    sops.secrets = lib.mkMerge (
      mapAttrsToList (
        name: env:
        genAttrs (map (secretName name) env.keys) (
          sname:
          {
            sopsFile = env.file;
            format = "json";
            key = lib.removePrefix "stacks/${name}/" sname;
          }
        )
      ) envs
    );

    sops.templates = lib.mkMerge (
      mapAttrsToList (
        name: env:
        {
          "stacks/${name}.env" = {
            inherit (env) content;
            restartUnits = [ "stack-env-publish.service" ];
          };
        }
        // lib.mapAttrs' (
          part: content:
          lib.nameValuePair "stacks/${name}.${part}.env" {
            inherit content;
            restartUnits = [ "stack-env-publish.service" ];
          }
        ) env.parts
      ) envs
    );

    systemd.services.stack-env-publish = {
      description = "Publish rendered stack environments to /run/stack-env";
      wantedBy = [ "multi-user.target" ];
      # Komodo's own compose reads its environment from here at boot — and
      # BEFORE docker: dockerd restarts its containers as it starts, and a bind
      # mount whose source file does not exist yet makes docker create a
      # DIRECTORY there (Core's komodo-core.config.toml), which the publish
      # below would then move the real file into.
      before = [ "bootstrap-komodo.service" "docker.service" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      # Copy, never symlink: see the header. Every file under the stacks/
      # template prefix is published (the stack envs, and anything else a
      # container mounts from here, e.g. Komodo Core's git-provider config).
      # Each lands by rename, so a reader never sees a half-written one; a file
      # whose template is gone is removed. A failure fails the unit every time —
      # no suppression.
      script = ''
        umask 077
        src=/run/secrets/rendered/stacks
        dst=/run/stack-env
        install -d -m 0700 "$dst"
        for f in "$src"/*; do
          [ -f "$f" ] || continue
          n=$(basename "$f")
          # A directory where a file belongs is docker's bind-mount placeholder
          # (empty by construction); replace it, and say so — the container
          # that mounted it needs a restart to see the file.
          if [ -d "$dst/$n" ]; then
            rmdir "$dst/$n"
            echo "stack-env-publish: replaced docker's placeholder directory $dst/$n — restart its container" >&2
          fi
          install -m 0400 "$f" "$dst/.$n.tmp"
          mv -f "$dst/.$n.tmp" "$dst/$n"
        done
        for f in "$dst"/*; do
          [ -f "$f" ] || continue
          [ -e "$src/$(basename "$f")" ] || rm -f "$f"
        done
      '';

      onFailure = [ "notify-failure@%n.service" ];
    };
  };
}
