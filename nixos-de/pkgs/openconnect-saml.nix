# openconnect-saml — drives the Cisco SAML/SSO login that the openconnect CLI
# structurally cannot do itself, and prints the resulting session cookie.
#
# WHY THIS EXISTS AT ALL. openconnect's SSO dispatch (library.c) has exactly
# three arms: external-browser mode, a webview callback, or the error "No SSO
# handler". The CLI never registers a webview callback — only GUI frontends
# like NetworkManager's do — so its ONLY SSO path is external-browser mode,
# and that arm fires solely when the gateway sends <sso-v2-browser-mode>
# external. Epic's gateway does not send that element, so `openconnect` alone
# can never authenticate against it, with or without --external-browser. This
# is a missing capability, not a misconfiguration.
#
# WHY THIS PACKAGE and not vlaci/openconnect-sso, the better-known wrapper:
# that project's last commit was 2023-08 and its last release 2021-12, and its
# flake pins a 2021 nixpkgs that now fails to evaluate (infinite recursion).
# This is the maintained fork; it keeps the `--auth-only` mode that makes the
# tool usable as a pure credential source.
#
# WHY --auth-only MATTERS SO MUCH: the tool's default behaviour is to find
# sudo/doas and run openconnect ITSELF, which would create a tun device and
# rewrite the routing table — destroying the entire point of the ocproxy
# design in modules/home/work-vpn.nix. --auth-only makes it authenticate,
# print HOST/COOKIE/FINGERPRINT, and exit, so the unprivileged --script-tun
# tunnel stays exactly as it was and only the auth step changes.
#
# Only the `gui` extra is wired up: the Qt6 WebEngine backend. The `chrome`
# extra would pull Playwright and its own downloaded Chromium (which does not
# work under Nix without extra plumbing), and headless mode cannot survive an
# interactive MFA prompt.
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
