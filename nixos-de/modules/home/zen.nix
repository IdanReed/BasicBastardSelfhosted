{ config, pkgs, inputs, ... }:

{
  xdg.mimeApps = {
    enable = true;
    defaultApplications = {
      "text/html" = [ "zen.desktop" ];
      "x-scheme-handler/http" = [ "zen.desktop" ];
      "x-scheme-handler/https" = [ "zen.desktop" ];
      "x-scheme-handler/about" = [ "zen.desktop" ];
      "x-scheme-handler/unknown" = [ "zen.desktop" ];
    };
  };

  home.sessionVariables.BROWSER = "zen";

  programs.zen-browser = {
    enable = true;
    profiles.default = {
      settings = {
        "browser.shell.checkDefaultBrowser" = false;
      };
    };
    policies.ExtensionSettings = {
      "{446900e4-71c2-419f-a6a7-df9c091e268b}" = {
        install_url = "https://addons.mozilla.org/firefox/downloads/latest/bitwarden-password-manager/latest.xpi";
        installation_mode = "force_installed";
      };
      "uBlock0@raymondhill.net" = {
        install_url = "https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/latest.xpi";
        installation_mode = "force_installed";
      };
      "jid1-MnnxcxisBPnSXQ@jetpack" = {
        install_url = "https://addons.mozilla.org/firefox/downloads/latest/privacy-badger17/latest.xpi";
        installation_mode = "force_installed";
      };
      "sponsorBlocker@ajay.app" = {
        install_url = "https://addons.mozilla.org/firefox/downloads/latest/sponsorblock/latest.xpi";
        installation_mode = "force_installed";
      };
      # ClearURLs mangles OAuth params on accounts.google.com and breaks
      # "Sign in with Google" (upstream ClearURLs/Addon#272, #329, both open,
      # no domain whitelist). normal_installed instead of force_installed so it
      # stays toggleable from about:addons when a login flow needs it off.
      "{74145f27-f039-47ce-a470-a662b129930a}" = {
        install_url = "https://addons.mozilla.org/firefox/downloads/latest/clearurls/latest.xpi";
        installation_mode = "normal_installed";
      };
      "addon@darkreader.org" = {
        install_url = "https://addons.mozilla.org/firefox/downloads/latest/darkreader/latest.xpi";
        installation_mode = "force_installed";
      };
      "{aecec67f-0d10-4fa7-b7c7-609a2db280cf}" = {
        install_url = "https://addons.mozilla.org/firefox/downloads/latest/violentmonkey/latest.xpi";
        installation_mode = "force_installed";
      };
    };
  };
}
