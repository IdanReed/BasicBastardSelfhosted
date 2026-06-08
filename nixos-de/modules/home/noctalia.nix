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

      location = {
        name = "Madison, WI";
        weatherEnabled = true;
        useFahrenheit = true;
        autoLocate = false;
      };
    };
  };
}
