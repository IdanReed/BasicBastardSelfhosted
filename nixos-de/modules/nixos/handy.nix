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
  #
  # A bare `KERNEL=="uinput", GROUP="input", MODE="0660"` rule looks right and
  # does nothing. /dev/uinput is a *static node*: systemd pre-creates it (root
  # root 0600) so that opening it autoloads the module. udev rules only run on
  # device-add events, and no device is ever added until uinput is loaded, so
  # the rule never fires and the node keeps its default 0600. hardware.uinput
  # supplies both missing halves — boot.kernelModules to actually load the
  # module, and OPTIONS+="static_node=uinput" to apply the mode to the
  # pre-created node regardless. It grants the "uinput" group, not "input".
  hardware.uinput.enable = true;

  # input  -> read /dev/input/event*   (observe key press/release)
  # uinput -> write /dev/uinput        (EVIOCGRAB clone, swallows the hotkey)
  users.users.idan.extraGroups = [ "input" "uinput" ];
}
