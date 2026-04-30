{ config, pkgs, lib, ... }:

{
  programs.waybar = {
    enable = true;

    settings.mainBar = {
      layer = "top";
      position = "top";
      height = 32;
      spacing = 8;

      modules-left = [ "niri/workspaces" "niri/window" ];
      modules-center = [ "clock" ];
      modules-right = [ "pulseaudio" "network" "cpu" "memory" "temperature" "tray" ];

      "niri/workspaces" = {
        format = "{icon}";
        format-icons = { "1" = "1"; "2" = "2"; "3" = "3"; "4" = "4"; "5" = "5"; default = ""; };
        on-click = "activate";
      };

      "niri/window" = {
        format = "{title}";
        max-length = 50;
        rewrite = {
          "(.*) — Mozilla Firefox" = " $1";
          "(.*) - zen" = " $1";
          "foot" = " Terminal";
          "(.*) - nvim" = " $1";
        };
      };

      clock = {
        format = "{:%H:%M}";
        format-alt = "{:%A, %B %d, %Y}";
        tooltip-format = "<tt><small>{calendar}</small></tt>";
      };

      pulseaudio = {
        format = "{icon} {volume}%";
        format-muted = "󰝟 Muted";
        format-icons.default = [ "󰕿" "󰖀" "󰕾" ];
        on-click = "pamixer -t";
        on-click-right = "pavucontrol";
        scroll-step = 5;
      };

      network = {
        format-wifi = "󰖩 {signalStrength}%";
        format-ethernet = "󰈀 {ipaddr}";
        format-disconnected = "󰖪 Offline";
        on-click = "foot -e nmtui";
      };

      cpu = { format = "󰻠 {usage}%"; interval = 5; };
      memory = { format = "󰍛 {percentage}%"; interval = 5; };
      temperature = {
        format = "󰔏 {temperatureC}°C";
        critical-threshold = 80;
        format-critical = "󰸁 {temperatureC}°C";
      };
      tray = { icon-size = 18; spacing = 8; };
    };

    style = ''
      * {
        font-family: "JetBrainsMono Nerd Font";
        font-size: 13px;
        min-height: 0;
      }
      window#waybar {
        background: alpha(@base00, 0.9);
        border-bottom: 2px solid @base02;
      }
      #workspaces button {
        padding: 0 8px;
        border-radius: 4px;
        margin: 4px 2px;
      }
      #workspaces button.active {
        background: @base0A;
        color: @base00;
      }
      #workspaces button:hover { background: @base03; }
      #window { padding: 0 12px; color: @base05; }
      #clock { font-weight: bold; color: @base0D; }
      #pulseaudio, #network, #cpu, #memory, #temperature, #tray {
        padding: 0 10px;
        margin: 4px 2px;
        border-radius: 4px;
        background: @base01;
      }
      #pulseaudio { color: @base0B; }
      #network { color: @base0C; }
      #cpu { color: @base0A; }
      #memory { color: @base0E; }
      #temperature { color: @base09; }
      #temperature.critical { color: @base08; }
    '';
  };
}
