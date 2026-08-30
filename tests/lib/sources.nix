# Resolves nixpkgs and sops-nix from a sibling host flake's lock file.
#
# The harness deliberately does NOT carry its own flake.lock. Pinning from the
# host's lock means the tests are evaluated against exactly the nixpkgs the
# host is built with — if headscale-vps bumps nixpkgs, the suite follows on the
# next run and no separate `nix flake update` can silently drift the two apart.
#
# flake.lock's narHash is the NAR hash of the unpacked source tree, which is
# the same thing builtins.fetchTarball's sha256 wants, so the lock entry can be
# consumed directly without re-hashing.

{ lockFile }:

let
  # A missing lock is a hard error, not a fallback: both host flakes have a
  # committed flake.lock, so its absence means the harness is being pointed at
  # the wrong directory — silently fetching something else would make every
  # "pinned from the host's lock" guarantee above a lie.
  lock =
    if builtins.pathExists lockFile then
      builtins.fromJSON (builtins.readFile lockFile)
    else
      throw "tests/lib/sources.nix: ${toString lockFile} does not exist — the host flakes commit their locks, so this path is wrong";

  # An input's NAME is not its node LABEL: `follows` and duplicate transitive
  # inputs give nodes labels like "nixpkgs_2", and lock["nodes"]["nixpkgs"]
  # can then be a *transitive* input rather than the flake's own. Resolve
  # through the root node's inputs mapping, the way Nix itself does, so the
  # node fetched is always the one the host flake actually uses.
  rootInputs = lock.nodes.${lock.root}.inputs;

  resolveNode =
    name:
    let
      label =
        rootInputs.${name} or (throw "tests/lib/sources.nix: no '${name}' input in ${toString lockFile}");
    in
    # A list value is a follows-path ("a/b/c"); a flake's own top-level inputs
    # are always plain labels, so hitting one means the lock shape changed.
    if !builtins.isString label then
      throw "tests/lib/sources.nix: root input '${name}' is a follows path, which is not supported"
    else
      lock.nodes.${label};

  fetchNode =
    name:
    let
      l = (resolveNode name).locked;
    in
    if l.type != "github" then
      throw "tests/lib/sources.nix: only github inputs are supported, '${name}' is '${l.type}'"
    else
      builtins.fetchTarball {
        url = "https://github.com/${l.owner}/${l.repo}/archive/${l.rev}.tar.gz";
        sha256 = l.narHash;
      };
in
{
  nixpkgs = fetchNode "nixpkgs";
  sops-nix = fetchNode "sops-nix";
  disko = fetchNode "disko";

  # Exposed so lints can assert the other host flakes pin the same nixpkgs.
  nixpkgsRev = (resolveNode "nixpkgs").locked.rev;
}
