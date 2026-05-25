{ config, pkgs, ... }:

{
  services.mako = {
    enable = true;
    settings = {
      border-radius = 8;
      border-size = 2;
      padding = "12";
      margin = "12";
      anchor = "top-right";
      layer = "overlay";
      default-timeout = 5000;
      ignore-timeout = false;
      max-visible = 5;
      sort = "-time";
      icons = true;
      max-icon-size = 48;
      markup = true;
      actions = true;
      format = "<b>%s</b>\\n%b";
      width = 350;
      height = 150;

      "urgency=low" = {
        default-timeout = 3000;
      };

      "urgency=critical" = {
        default-timeout = 0;
        ignore-timeout = true;
      };
    };
  };
}
