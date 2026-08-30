# Excalidraw diagram toolchain, available on PATH everywhere — the point is for
# coding agents to have it in any repo, not just this one.
#
# The intended loop is two-step, because writing Excalidraw JSON by hand gets
# layout wrong far more often than it gets syntax wrong:
#
#   mmd2excalidraw docs/arch.mmd -o docs/arch.excalidraw   # mermaid is the source
#   excalirender docs/arch.excalidraw -o /tmp/arch.png     # then look at it
#
# Keep the .mmd as the editable source and treat the .excalidraw as generated.
# Rendering doubles as the validator: a scene that renders is a scene that
# parses, and the PNG is the only way to catch overlapping shapes or an arrow
# bound to nothing.
{ pkgs, ... }:

{
  home.packages = [
    (pkgs.callPackage ../../pkgs/excalirender.nix { })
    (pkgs.callPackage ../../pkgs/mmd2excalidraw { })
  ];
}
