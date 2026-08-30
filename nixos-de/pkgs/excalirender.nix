# excalirender — render .excalidraw files to PNG/SVG/PDF from the command line.
#
# Not in nixpkgs, and upstream publishes no buildable source release: the only
# Linux artifact is a Bun-compiled binary. That tarball vendors every non-glibc
# shared object it needs under lib/, so the whole job here is repointing the ELF
# interpreter and RUNPATHs at the store. autoPatchelfHook discovers the vendored
# libs from the output itself, so nothing beyond glibc/libstdc++ is needed.
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

  # bin/excalirender.bin is a Bun single-file executable: the JavaScript payload
  # is appended after the ELF image and located at runtime by scanning back from
  # end-of-file for a "---- Bun! ----" trailer. Stripping discards everything
  # past the last section, so the default strip silently turns this into a plain
  # Bun runtime that tries to *execute* the .excalidraw file it was handed.
  dontStrip = true;

  # The upstream bin/excalirender wrapper resolves its own location with
  # `readlink -f`, so it still finds lib/ and etc/fonts through the symlink.
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
