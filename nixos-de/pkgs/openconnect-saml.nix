# openconnect-saml — drives the Cisco SAML/SSO login the openconnect CLI
# structurally cannot do (its only SSO arm needs <sso-v2-browser-mode> external,
# which this gateway does not send) and prints the session cookie.
#
# This fork, not vlaci/openconnect-sso: that one is unmaintained since 2023 and
# its flake pins a 2021 nixpkgs that no longer evaluates. Critically it keeps
# --auth-only, which prints HOST/COOKIE/FINGERPRINT and exits instead of finding
# sudo and running openconnect itself — the default would create a tun device
# and destroy the ocproxy design in modules/home/work-vpn.nix.
#
# Only the `gui` extra: `chrome` pulls its own Chromium (broken under Nix), and
# headless cannot survive an interactive MFA prompt.
{
  lib,
  python3Packages,
  fetchFromGitHub,
  openconnect,
  qt6,
  libfido2,
}:

python3Packages.buildPythonApplication rec {
  pname = "openconnect-saml";
  version = "0.24.5";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "mschabhuettl";
    repo = "openconnect-saml";
    tag = "v${version}";
    hash = "sha256-4efr1EyewHzaaCZ2bRg22W1lqq/PlaccbQWG7ZA9bTM=";
  };

  build-system = [ python3Packages.hatchling ];

  dependencies = with python3Packages; [
    attrs
    colorama
    keyring
    lxml
    prompt-toolkit
    pyotp
    pysocks
    pyxdg
    requests
    structlog
    toml
    # `gui` extra — the Qt6 WebEngine browser that renders the IdP login page.
    pyqt6
    pyqt6-webengine
  ];

  # Standard nixpkgs idiom for a Python app that ships Qt: let wrapQtAppsHook
  # compute the Qt environment but not wrap anything itself, then fold its
  # arguments into the wrapper buildPythonApplication already makes. Without
  # this the WebEngine process aborts at startup on a missing QtWebEngine
  # resource path.
  nativeBuildInputs = [ qt6.wrapQtAppsHook ];
  # qtbase is what tells the hook where the Qt plugin prefix is; without it
  # the hook aborts with "qtPluginPrefix is unset".
  buildInputs = [ qt6.qtbase ];
  dontWrapQtApps = true;
  preFixup = ''
    makeWrapperArgs+=("''${qtWrapperArgs[@]}")
  '';

  # The tool shells out to `openconnect` in its default (non --auth-only)
  # mode. work-vpn never uses that path, but a tool that silently lacks its
  # own dependency is a trap for anyone running it by hand.
  makeWrapperArgs = [
    "--prefix PATH : ${lib.makeBinPath [ openconnect ]}"
    # QtWebEngine dlopens libfido2 at runtime to drive USB security keys; it
    # is not a link-time dependency, so without this on the library path
    # WebAuthn/FIDO2 prompts fail SILENTLY (the tool warns about it at
    # startup). Harmless if no key is ever used.
    "--prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ libfido2 ]}"
  ];

  # Upstream ships no test suite in the sdist, and importing the top-level
  # module pulls in Qt, which needs a display.
  doCheck = false;
  pythonImportsCheck = [ ];

  meta = {
    description = "OpenConnect wrapper adding Cisco SAML/SSO (Azure AD, Okta) authentication";
    homepage = "https://github.com/mschabhuettl/openconnect-saml";
    license = lib.licenses.gpl3Plus;
    mainProgram = "openconnect-saml";
    platforms = lib.platforms.linux;
  };
}
