# The VPS's module set, shared by the root flake and tests/default.nix so the
# lints evaluate exactly what the host deploys. disk-config.nix is added by the
# flake alone: it needs disko's module, and the disko suite covers it.
{
  imports = [
    ./configuration.nix
    ./modules/caddy.nix
    ./modules/headscale.nix
    ./modules/authentik.nix
    ./modules/log-shipper.nix
  ];
}
