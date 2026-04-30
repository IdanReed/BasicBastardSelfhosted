{ config, pkgs, ... }:

{
  programs.foot = {
    enable = true;

    settings = {
      main = {
        term = "xterm-256color";
        shell = "${pkgs.zsh}/bin/zsh";
        pad = "8x8";
        initial-window-size-chars = "120x35";
      };

      scrollback = {
        lines = 10000;
        multiplier = 3.0;
      };

      cursor = {
        style = "beam";
        blink = "yes";
        beam-thickness = 1.5;
      };

      mouse.hide-when-typing = "yes";

      url = {
        launch = "xdg-open \${url}";
        protocols = "http, https, ftp, ftps, file, gemini, gopher";
      };

      key-bindings = {
        clipboard-copy = "Control+Shift+c";
        clipboard-paste = "Control+Shift+v";
        search-start = "Control+Shift+f";
        font-increase = "Control+plus Control+equal";
        font-decrease = "Control+minus";
        font-reset = "Control+0";
        scrollback-up-page = "Shift+Page_Up";
        scrollback-down-page = "Shift+Page_Down";
        spawn-terminal = "Control+Shift+n";
      };
    };
  };
}
