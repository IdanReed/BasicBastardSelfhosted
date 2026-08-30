{ config, pkgs, lib, ... }:

{
  # Handy's push-to-talk needs its evdev hotkey backend ("handy_keys"), because
  # the default Tauri backend grabs shortcuts through X11 and never fires under
  # niri. handy-keys instead polls /dev/input/event* directly, which is
  # display-server independent and — unlike a niri bind — reports key release
  # as well as press, so "record while held" is actually expressible.
  #
  # Two permissions are required for that, both granted by the input group:
  #
  #   read  /dev/input/event*  observe key press/release (already root:input 0660)
  #   write /dev/uinput        Handy always calls HotkeyManager::new_with_blocking(),
  #                            which grabs each keyboard exclusively (EVIOCGRAB)
  #                            and re-injects non-hotkey events through a uinput
  #                            clone. That is what stops Ctrl+Space from also
  #                            reaching the focused app.
  #
  # Mirrors upstream's nixosModules.default, minus its environment.systemPackages
  # entry — the package is installed through home-manager (modules/home/handy.nix).
  users.users.idan.extraGroups = [ "input" ];

  # Default is crw------- root root, which locks out the input group.
  services.udev.extraRules = ''
    KERNEL=="uinput", GROUP="input", MODE="0660"
  '';
}
