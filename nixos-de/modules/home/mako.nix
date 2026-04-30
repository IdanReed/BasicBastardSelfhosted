{ config, pkgs, ... }:

{
  services.mako = {
    enable = true;
    borderRadius = 8;
    borderSize = 2;
    padding = "12";
    margin = "12";
    anchor = "top-right";
    layer = "overlay";
    defaultTimeout = 5000;
    ignoreTimeout = false;
    maxVisible = 5;
    sort = "-time";
    icons = true;
    maxIconSize = 48;
    markup = true;
    actions = true;
    format = "<b>%s</b>\\n%b";
    width = 350;
    height = 150;

    extraConfig = ''
      [urgency=low]
      default-timeout=3000

      [urgency=critical]
      default-timeout=0
      ignore-timeout=1
    '';
  };
}
