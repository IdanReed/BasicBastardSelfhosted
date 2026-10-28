# Test-level module added to every runNixOSTest (tests/default.nix).
#
# The suites address each VM by its system name, which is networking.hostName:
# `services_vm`, `headscale_vps`, not the `nodes.<key>` they are declared
# under (`services`, `vps`). The test driver names machines — the Python
# globals and the type-check stub alike — after the `nodes` keys, so this keys
# its VM table by system name instead. Nix-side references (`nodes.vps.…`)
# keep the attribute key; only the driver's names change.

{ config, lib, ... }:

let
  systemNames = lib.mapAttrsToList (_: node: node.system.name) config.nodes;
in
{
  driverConfiguration.vms = lib.mkForce (
    if lib.length (lib.unique systemNames) != lib.length systemNames then
      throw "tests/lib/machine-names.nix: two nodes share a system name (${toString systemNames}); the driver would see one machine"
    else
      lib.mapAttrs' (
        _: node:
        lib.nameValuePair node.system.name {
          name = node.system.name;
          start_script = lib.getExe node.system.build.vm;
        }
      ) config.nodes
  );
}
