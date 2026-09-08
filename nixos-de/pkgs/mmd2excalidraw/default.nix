# mmd2excalidraw — Mermaid (.mmd) to Excalidraw, with layout from mermaid's own
# dagre pass instead of hand-written coordinates.
#
# Mermaid parses against a real DOM, hence headless Chromium — from nixpkgs'
# playwright-driver, because playwright's own download is not patchelf'd.
# Playwright refuses a bundle whose revision does not match the client library,
# so the lockfile pins playwright to playwright-driver's version: bump together.
{
  lib,
  buildNpmPackage,
  fetchurl,
  makeWrapper,
  playwright-driver,
}:

buildNpmPackage (finalAttrs: {
  pname = "mmd2excalidraw";
  version = "0.1.3";

  src = fetchurl {
    url = "https://registry.npmjs.org/mermaid-to-excalidraw-cli/-/mermaid-to-excalidraw-cli-${finalAttrs.version}.tgz";
    hash = "sha256-/Hca9sCCKOoWR0tgqwEwChYyv3K26Fj3VM5VCxk3oNw=";
  };

  # The published tarball ships no lockfile. Ours was generated from upstream's
  # unmodified package.json, so `npm ci` still validates against it.
  postPatch = ''
    cp ${./package-lock.json} package-lock.json
  '';

  npmDepsHash = "sha256-NT5I0A7dpKEXbqb/+pkjOvPB5ftRePXTYYGaSt4IaQI=";

  # Pure-JS dependency tree; skipping install scripts also keeps playwright's
  # postinstall from reaching for the network inside the build sandbox.
  npmFlags = [ "--ignore-scripts" ];
  dontNpmBuild = true;

  nativeBuildInputs = [ makeWrapper ];

  postInstall = ''
    wrapProgram $out/bin/mmd2excalidraw \
      --set PLAYWRIGHT_BROWSERS_PATH ${playwright-driver.browsers} \
      --set PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS true
  '';

  meta = {
    description = "Convert Mermaid diagrams to Excalidraw scenes using headless Chromium";
    homepage = "https://github.com/ayurkin/mermaid-to-excalidraw-cli";
    license = lib.licenses.mit;
    mainProgram = "mmd2excalidraw";
    platforms = lib.platforms.linux;
  };
})
