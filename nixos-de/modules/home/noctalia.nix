{ config, pkgs, lib, ... }:

{
  # Noctalia ships defaults that work out-of-the-box. The settings.json schema
  # is free-form upstream — tune via the in-app settings panel after first
  # login, then mirror the resulting ~/.config/noctalia/settings.json here.
  # Autostart is via niri's spawn-at-startup (see modules/home/niri.nix);
  # upstream deprecated systemd startup due to IPC reliability issues.
  programs.noctalia-shell = {
    enable = true;
    settings = { };
  };
}
