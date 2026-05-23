{ config, pkgs, lib, ... }:

{
  programs.niri = {
    settings = {
      input = {
        keyboard = {
          xkb.layout = "us";
          repeat-delay = 300;
          repeat-rate = 50;
        };
        mouse = {
          accel-speed = 0.0;
          accel-profile = "flat";
        };
        touchpad = {
          tap = true;
          natural-scroll = true;
          accel-speed = 0.2;
          accel-profile = "adaptive";
        };
        focus-follows-mouse = {
          enable = true;
          max-scroll-amount = "25%";
        };
      };

      # Monitor configuration - uncomment and adjust after finding names with:
      #   niri msg outputs
      # outputs = {
      #   "DP-1" = {
      #     scale = 1.5;  # 4K monitor
      #     position = { x = 0; y = 0; };
      #   };
      #   "DP-2" = {
      #     scale = 1.0;  # 1080p monitor
      #     position = { x = 2560; y = 0; };
      #   };
      # };

      layout = {
        gaps = 8;
        center-focused-column = "never";
        preset-column-widths = [
          { proportion = 1.0 / 3.0; }
          { proportion = 1.0 / 2.0; }
          { proportion = 2.0 / 3.0; }
        ];
        default-column-width = { proportion = 1.0 / 2.0; };
        focus-ring = {
          enable = true;
          width = 2;
          active.color = "#fe8019";
          inactive.color = "#665c54";
        };
        border.enable = false;
        struts.top = 32;  # Space for waybar
      };

      # Use default animations (niri flake simplified animation options)
      animations = {
        slowdown = 1.0;
      };

      spawn-at-startup = [
        { command = [ "waybar" ]; }
        { command = [ "mako" ]; }
        { command = [ "${pkgs.xwayland-satellite}/bin/xwayland-satellite" ]; }
        { command = [ "${pkgs.swaybg}/bin/swaybg" "-m" "fill" "-i" "${config.stylix.image}" ]; }
      ];

      window-rules = [
        { matches = [{ app-id = "^pavucontrol$"; }]; open-floating = true; }
        { matches = [{ app-id = "^nm-connection-editor$"; }]; open-floating = true; }
        { matches = [{ app-id = "^zen"; }]; default-column-width = { proportion = 2.0 / 3.0; }; }
      ];

      # Keybindings - using spawn for most actions as niri flake actions change frequently
      binds = with config.lib.niri.actions; {
        # App launchers
        "Mod+Return".action = spawn "foot";
        "Mod+D".action = spawn "fuzzel";
        "Mod+B".action = spawn "zen";
        "Mod+E".action = spawn "foot" "-e" "yazi";
        "Mod+Q".action = close-window;

        # Focus navigation
        "Mod+H".action = focus-column-left;
        "Mod+J".action = focus-window-down;
        "Mod+K".action = focus-window-up;
        "Mod+L".action = focus-column-right;

        # Move windows
        "Mod+Shift+H".action = move-column-left;
        "Mod+Shift+J".action = move-window-down;
        "Mod+Shift+K".action = move-window-up;
        "Mod+Shift+L".action = move-column-right;

        # Workspaces
        "Mod+1".action = focus-workspace 1;
        "Mod+2".action = focus-workspace 2;
        "Mod+3".action = focus-workspace 3;
        "Mod+4".action = focus-workspace 4;
        "Mod+5".action = focus-workspace 5;
        "Mod+Tab".action = focus-workspace-down;
        "Mod+Shift+Tab".action = focus-workspace-up;

        # Window sizing
        "Mod+F".action = maximize-column;
        "Mod+Shift+F".action = fullscreen-window;

        # Screenshot (using grim)
        "Print".action = spawn "grim";

        # Media keys (using spawn to avoid action name changes)
        "XF86AudioRaiseVolume".action = spawn "pamixer" "-i" "5";
        "XF86AudioLowerVolume".action = spawn "pamixer" "-d" "5";
        "XF86AudioMute".action = spawn "pamixer" "-t";
        "XF86AudioPlay".action = spawn "playerctl" "play-pause";
        "XF86AudioNext".action = spawn "playerctl" "next";
        "XF86AudioPrev".action = spawn "playerctl" "previous";
        "XF86MonBrightnessUp".action = spawn "brightnessctl" "set" "+5%";
        "XF86MonBrightnessDown".action = spawn "brightnessctl" "set" "5%-";

        # Session
        "Mod+Shift+E".action = quit;
      };
    };
  };
}
