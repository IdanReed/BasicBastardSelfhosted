{ config, pkgs, lib, ... }:

{
  # Noctalia ships defaults that work out-of-the-box. The settings.json schema
  # is free-form upstream — tune via the in-app settings panel after first
  # login, then mirror the resulting ~/.config/noctalia/settings.json here.
  # Autostart is via niri's spawn-at-startup (see modules/home/niri.nix);
  # upstream deprecated systemd startup due to IPC reliability issues.
  programs.noctalia-shell = {
    enable = true;
    settings = {
      # Terminal wrapper for desktop entries with Terminal=true (yazi, htop, btop…).
      # Without this, noctalia's launcher spawns the bare Exec line with no tty
      # and the TUI dies on start.
      appLauncher.terminalCommand = "foot -e";

      bar.outerCorners = false;
      general.enableShadows = false;

      # Clock lives in bar.widgets.left as an atomic list, so restate the
      # whole left section to override just the Clock's time format.
      # Qt QLocale format: `h` is 12-hour when `ap`/`AP` is present.
      bar.widgets.left = [
        { id = "Launcher"; }
        {
          id = "Clock";
          formatHorizontal = "h:mm ap ddd, MMM dd";
          tooltipFormat = "h:mm ap ddd, MMM dd";
        }
        { id = "SystemMonitor"; }
        { id = "ActiveWindow"; }
        { id = "MediaMini"; }
      ];

      location = {
        name = "Madison, WI";
        weatherEnabled = true;
        useFahrenheit = true;
        autoLocate = false;
      };
    };
  };
}
