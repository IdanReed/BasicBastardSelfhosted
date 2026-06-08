{ config, pkgs, lib, inputs, ... }:

{
  programs.niri = {
    package = inputs.niri.packages.${pkgs.stdenv.hostPlatform.system}.niri-unstable;
    settings = {
      prefer-no-csd = true;

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
          { proportion = 0.25; }
          { proportion = 0.5; }
          { proportion = 0.75; }
        ];
        default-column-width = { proportion = 1.0 / 2.0; };
        focus-ring = {
          enable = true;
          width = 2;
          active.color = "#fe8019";
          inactive.color = "#665c54";
        };
        border.enable = false;
      };

      # Use default animations (niri flake simplified animation options)
      animations = { slowdown = 1.0; };

      spawn-at-startup = [
        { command = [ "${pkgs.xwayland-satellite}/bin/xwayland-satellite" ]; }
        # DISPLAY=:0 is forced because quickshell (noctalia's runtime) exits on
        # an empty DISPLAY, and there's a race with xwayland-satellite at niri
        # startup. xwayland-satellite always claims :0 on this machine.
        { command = [ "sh" "-c" "DISPLAY=:0 exec noctalia-shell" ]; }
      ];

      window-rules = [
        {
          matches = [{ app-id = "^pavucontrol$"; }];
          open-floating = true;
        }
        {
          matches = [{ app-id = "^nm-connection-editor$"; }];
          open-floating = true;
        }
        {
          matches = [{ app-id = "^zen"; }];
          default-column-width = { proportion = 2.0 / 3.0; };
        }
      ];

      binds = with config.lib.niri.actions; {
        "Mod+Shift+Slash" = { action = show-hotkey-overlay; hotkey-overlay.title = "Show hotkey overlay"; };

        # App launchers
        "Mod+Return" = { action = spawn "foot"; hotkey-overlay.title = "Terminal (foot)"; };
        "Mod+D"      = { action = spawn "noctalia-shell" "ipc" "call" "launcher" "toggle"; hotkey-overlay.title = "App launcher (noctalia)"; };
        "Mod+B"      = { action = spawn "zen"; hotkey-overlay.title = "Browser (zen)"; };
        "Mod+E"      = { action = spawn "foot" "-e" "yazi"; hotkey-overlay.title = "File manager (yazi)"; };
        "Mod+N"      = { action = spawn "nautilus"; hotkey-overlay.title = "File manager (nautilus)"; };
        "Mod+Q"      = { action = close-window; hotkey-overlay.title = "Close window"; };

        # Focus: column/window
        "Mod+H"    = { action = focus-column-left; hotkey-overlay.title = "Focus column left"; };
        "Mod+L"    = { action = focus-column-right; hotkey-overlay.title = "Focus column right"; };
        "Mod+J"    = { action = focus-window-down; hotkey-overlay.title = "Focus window down"; };
        "Mod+K"    = { action = focus-window-up; hotkey-overlay.title = "Focus window up"; };
        "Mod+Home" = { action = focus-column-first; hotkey-overlay.title = "Focus first column"; };
        "Mod+End"  = { action = focus-column-last; hotkey-overlay.title = "Focus last column"; };

        # Move: column/window
        "Mod+Shift+H"    = { action = move-column-left; hotkey-overlay.title = "Move column left"; };
        "Mod+Shift+L"    = { action = move-column-right; hotkey-overlay.title = "Move column right"; };
        "Mod+Shift+J"    = { action = move-window-down; hotkey-overlay.title = "Move window down"; };
        "Mod+Shift+K"    = { action = move-window-up; hotkey-overlay.title = "Move window up"; };
        "Mod+Shift+Home" = { action = move-column-to-first; hotkey-overlay.title = "Move column to first"; };
        "Mod+Shift+End"  = { action = move-column-to-last; hotkey-overlay.title = "Move column to last"; };

        # Focus monitor
        "Mod+Ctrl+H" = { action = focus-monitor-left; hotkey-overlay.title = "Focus monitor left"; };
        "Mod+Ctrl+J" = { action = focus-monitor-down; hotkey-overlay.title = "Focus monitor down"; };
        "Mod+Ctrl+K" = { action = focus-monitor-up; hotkey-overlay.title = "Focus monitor up"; };
        "Mod+Ctrl+L" = { action = focus-monitor-right; hotkey-overlay.title = "Focus monitor right"; };

        # Move column to monitor
        "Mod+Ctrl+Shift+H" = { action = move-column-to-monitor-left; hotkey-overlay.title = "Move column to monitor left"; };
        "Mod+Ctrl+Shift+J" = { action = move-column-to-monitor-down; hotkey-overlay.title = "Move column to monitor down"; };
        "Mod+Ctrl+Shift+K" = { action = move-column-to-monitor-up; hotkey-overlay.title = "Move column to monitor up"; };
        "Mod+Ctrl+Shift+L" = { action = move-column-to-monitor-right; hotkey-overlay.title = "Move column to monitor right"; };

        # Workspaces
        "Mod+1" = { action = focus-workspace 1; hotkey-overlay.title = "Focus workspace 1"; };
        "Mod+2" = { action = focus-workspace 2; hotkey-overlay.title = "Focus workspace 2"; };
        "Mod+3" = { action = focus-workspace 3; hotkey-overlay.title = "Focus workspace 3"; };
        "Mod+4" = { action = focus-workspace 4; hotkey-overlay.title = "Focus workspace 4"; };
        "Mod+5" = { action = focus-workspace 5; hotkey-overlay.title = "Focus workspace 5"; };
        "Mod+Tab"       = { action = focus-workspace-down; hotkey-overlay.title = "Focus workspace down"; };
        "Mod+Shift+Tab" = { action = focus-workspace-up; hotkey-overlay.title = "Focus workspace up"; };
        "Mod+Shift+1" = { action.move-column-to-workspace = 1; hotkey-overlay.title = "Move column to workspace 1"; };
        "Mod+Shift+2" = { action.move-column-to-workspace = 2; hotkey-overlay.title = "Move column to workspace 2"; };
        "Mod+Shift+3" = { action.move-column-to-workspace = 3; hotkey-overlay.title = "Move column to workspace 3"; };
        "Mod+Shift+4" = { action.move-column-to-workspace = 4; hotkey-overlay.title = "Move column to workspace 4"; };
        "Mod+Shift+5" = { action.move-column-to-workspace = 5; hotkey-overlay.title = "Move column to workspace 5"; };
        "Mod+Ctrl+Tab"       = { action = move-column-to-workspace-down; hotkey-overlay.title = "Move column to workspace down"; };
        "Mod+Ctrl+Shift+Tab" = { action = move-column-to-workspace-up; hotkey-overlay.title = "Move column to workspace up"; };
        "Mod+Shift+Page_Down" = { action = move-workspace-down; hotkey-overlay.title = "Move workspace down"; };
        "Mod+Shift+Page_Up"   = { action = move-workspace-up; hotkey-overlay.title = "Move workspace up"; };

        # Consume/expel windows in/out of columns
        "Mod+BracketLeft"  = { action = consume-or-expel-window-left; hotkey-overlay.title = "Consume/expel window left"; };
        "Mod+BracketRight" = { action = consume-or-expel-window-right; hotkey-overlay.title = "Consume/expel window right"; };
        "Mod+Comma"        = { action = consume-window-into-column; hotkey-overlay.title = "Consume window into column"; };
        "Mod+Period"       = { action = expel-window-from-column; hotkey-overlay.title = "Expel window from column"; };

        # Column width — Minus/Equal step through preset marks (25/50/75)
        "Mod+Minus"   = { action = switch-preset-column-width-back; hotkey-overlay.title = "Column width: prev preset (25/50/75)"; };
        "Mod+Equal"   = { action = switch-preset-column-width;      hotkey-overlay.title = "Column width: next preset (25/50/75)"; };
        "Mod+Ctrl+1"  = { action = set-column-width "25%";  hotkey-overlay.title = "Column width 25%"; };
        "Mod+Ctrl+2"  = { action = set-column-width "33.33%";  hotkey-overlay.title = "Column width 33%"; };
        "Mod+Ctrl+3"  = { action = set-column-width "50%";     hotkey-overlay.title = "Column width 50%"; };
        "Mod+Ctrl+4"  = { action = set-column-width "66.67%";  hotkey-overlay.title = "Column width 66%"; };
        "Mod+Ctrl+5"  = { action = set-column-width "75%";  hotkey-overlay.title = "Column width 75%"; };
        "Mod+C"       = { action = center-column; hotkey-overlay.title = "Center column"; };
        "Mod+Ctrl+C"  = { action = center-visible-columns; hotkey-overlay.title = "Center visible columns"; };

        # Window height
        "Mod+Ctrl+Shift+R" = { action = switch-preset-window-height; hotkey-overlay.title = "Cycle window height preset"; };
        "Mod+Ctrl+R"       = { action = reset-window-height; hotkey-overlay.title = "Reset window height"; };
        "Mod+Shift+Minus"  = { action = set-window-height "-10%"; hotkey-overlay.title = "Window height -10%"; };
        "Mod+Shift+Equal"  = { action = set-window-height "+10%"; hotkey-overlay.title = "Window height +10%"; };

        # Maximize / fullscreen / fill
        "Mod+F"       = { action = maximize-column; hotkey-overlay.title = "Maximize column"; };
        "Mod+Shift+F" = { action = fullscreen-window; hotkey-overlay.title = "Fullscreen window"; };
        "Mod+M"       = { action = maximize-window-to-edges; hotkey-overlay.title = "Maximize window to edges"; };
        "Mod+Ctrl+F"  = { action = expand-column-to-available-width; hotkey-overlay.title = "Expand column to available width"; };

        # Floating / tabbed display
        "Mod+V"       = { action = toggle-window-floating; hotkey-overlay.title = "Toggle window floating"; };
        "Mod+Shift+V" = { action = switch-focus-between-floating-and-tiling; hotkey-overlay.title = "Switch focus floating/tiling"; };
        "Mod+W"       = { action = toggle-column-tabbed-display; hotkey-overlay.title = "Toggle tabbed column display"; };

        # Overview
        "Mod+O" = { action = toggle-overview; hotkey-overlay.title = "Toggle overview"; };

        # Screenshots (niri built-in)
        "Print"      = { action.screenshot = { }; hotkey-overlay.title = "Screenshot (region)"; };
        "Ctrl+Print" = { action.screenshot-screen = { }; hotkey-overlay.title = "Screenshot (screen)"; };
        "Alt+Print"  = { action.screenshot-window = { }; hotkey-overlay.title = "Screenshot (window)"; };

        # Media keys (intentionally no title — kept out of the overlay)
        "XF86AudioRaiseVolume".action = spawn "pamixer" "-i" "5";
        "XF86AudioLowerVolume".action = spawn "pamixer" "-d" "5";
        "XF86AudioMute".action        = spawn "pamixer" "-t";
        "XF86AudioPlay".action        = spawn "playerctl" "play-pause";
        "XF86AudioNext".action        = spawn "playerctl" "next";
        "XF86AudioPrev".action        = spawn "playerctl" "previous";
        "XF86MonBrightnessUp".action   = spawn "brightnessctl" "set" "+5%";
        "XF86MonBrightnessDown".action = spawn "brightnessctl" "set" "5%-";

        # Session
        "Mod+Shift+P"     = { action = power-off-monitors; hotkey-overlay.title = "Power off monitors"; };
        "Mod+Escape"      = { action = toggle-keyboard-shortcuts-inhibit; allow-inhibiting = false; hotkey-overlay.title = "Toggle shortcut inhibit"; };
        "Mod+Shift+E"     = { action = quit; hotkey-overlay.title = "Quit niri"; };
        "Ctrl+Alt+Delete" = { action = quit; hotkey-overlay.title = "Quit niri"; };
      };
    };
  };
}
