# Excalidraw toolchain on PATH everywhere, so coding agents have it in any repo.
#
#   mmd2excalidraw docs/arch.mmd -o docs/arch.excalidraw   # mermaid is the source
#   excalirender docs/arch.excalidraw -o /tmp/arch.png     # rendering validates it
#
# Keep the .mmd editable and treat the .excalidraw as generated.
{ pkgs, ... }:

{
  home.packages = [
    (pkgs.callPackage ../../pkgs/excalirender.nix { })
    (pkgs.callPackage ../../pkgs/mmd2excalidraw { })
  ];
}
