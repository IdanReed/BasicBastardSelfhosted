{ config, pkgs, ... }:

{
  programs.fuzzel = {
    enable = true;

    settings = {
      main = {
        icons-enabled = "yes";
        icon-theme = "Papirus-Dark";
        terminal = "${pkgs.foot}/bin/foot";
        layer = "overlay";
        lines = 12;
        width = 40;
        horizontal-pad = 20;
        vertical-pad = 15;
        inner-pad = 5;
        fuzzy = "yes";
        show-actions = "no";
      };

      border = {
        width = 2;
        radius = 8;
      };

      key-bindings = {
        execute = "Return Control+Return";
        execute-or-next = "Tab";
        cancel = "Escape Control+c";
        prev = "Up Control+k Control+p";
        next = "Down Control+j Control+n";
      };
    };
  };

  home.packages = [ pkgs.papirus-icon-theme ];
}
