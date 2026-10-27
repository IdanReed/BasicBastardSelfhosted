{ inputs, pkgs, ... }:

# herdr — agent multiplexer (tmux alternative with a server per machine, a
# thin SSH client and per-pane working/blocked state for Claude Code). Trial
# for the dev-env design (~/local/projects/server/dev-mgmt-research.md §3).
#
# Comes from the `nixpkgs-fresh` input, not `pkgs`: the locked nixpkgs predates
# the package and the locked home-manager has no `programs.herdr` module. Once
# `nfu` moves the main lock past 2026-10, switch to `pkgs.herdr` /
# `programs.herdr` and drop the extra input.
{
  home.packages = [
    inputs.nixpkgs-fresh.legacyPackages.${pkgs.stdenv.hostPlatform.system}.herdr
  ];
}
