# Resolves the harness's sources from a host flake's lock, so the suites
# evaluate against exactly the nixpkgs the host is built with and no separate
# `nix flake update` can drift the two apart. flake.lock's narHash is the NAR
# hash of the unpacked tree, which is what fetchTarball's sha256 wants.

{ lockFile }:

let
  # A missing lock means the harness is pointed at the wrong directory, so
  # fetching something else would make the pinning guarantee a lie.
  lock =
    if builtins.pathExists lockFile then
      builtins.fromJSON (builtins.readFile lockFile)
    else
      throw "tests/lib/sources.nix: ${toString lockFile} does not exist — the host flakes commit their locks, so this path is wrong";

  # An input's NAME is not its node LABEL — `follows` and duplicates yield
  # "nixpkgs_2", so nodes.nixpkgs can be a TRANSITIVE input. Resolve through
  # the root inputs mapping, the way Nix itself does.
  rootInputs = lock.nodes.${lock.root}.inputs;

  resolveNode =
    name:
    let
      label =
        rootInputs.${name} or (throw "tests/lib/sources.nix: no '${name}' input in ${toString lockFile}");
    in
    # A flake's own top-level inputs are always plain labels, so a list (a
    # follows-path) means the lock shape changed.
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
}
