{ ... }:

{
  # settings.json is free-form upstream — tune in the app, then mirror
  # ~/.config/noctalia/settings.json here. Autostart is niri spawn-at-startup
  # (modules/home/niri.nix); upstream deprecated the systemd path.
  programs.noctalia-shell = {
    enable = true;
    settings = {
      # Without this the launcher spawns Terminal=true entries with no tty and
      # the TUI dies on start.
      appLauncher.terminalCommand = "foot -e";

      bar.outerCorners = false;
      general.enableShadows = false;

      # Atomic list, so the whole left section is restated to change the Clock.
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
