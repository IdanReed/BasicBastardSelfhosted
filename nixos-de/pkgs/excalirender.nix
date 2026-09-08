# excalirender — render .excalidraw to PNG/SVG/PDF. Not in nixpkgs and upstream
# ships no buildable source, only a Bun-compiled binary that vendors its own
# libs, so this is purely an ELF interpreter/RUNPATH repoint.
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "excalirender";
  version = "1.10.5";

  src = fetchurl {
    url = "https://github.com/JonRC/excalirender/releases/download/v${finalAttrs.version}/excalirender-linux-x64.tar.gz";
    hash = "sha256-TMKRv7LLb7gm54aTpzs0EeGbgWFshEGCXMZ0XNDw0Oc=";
  };

  sourceRoot = "excalirender";

  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [ stdenv.cc.cc.lib ];

  # Bun single-file executable: the JS payload lives past the last ELF section,
  # so stripping silently leaves a bare Bun runtime that tries to *execute* the
  # .excalidraw file it was handed.
  dontStrip = true;

  # Upstream's wrapper resolves itself with `readlink -f`, so lib/ and etc/fonts
  # are still found through the symlink.
  installPhase = ''
    runHook preInstall

    mkdir -p $out/libexec/excalirender $out/bin
    cp -r bin lib etc $out/libexec/excalirender/
    ln -s $out/libexec/excalirender/bin/excalirender $out/bin/excalirender

    runHook postInstall
  '';

  meta = {
    description = "Render .excalidraw files to PNG, SVG and PDF without a browser";
    homepage = "https://github.com/JonRC/excalirender";
    license = lib.licenses.mit;
    mainProgram = "excalirender";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
