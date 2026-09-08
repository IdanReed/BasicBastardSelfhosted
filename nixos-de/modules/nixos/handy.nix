{ ... }:

# Handy's push-to-talk needs its evdev hotkey backend ("handy_keys"): the Tauri
# default grabs shortcuts through X11 and never fires under niri, and only evdev
# reports key RELEASE, without which "record while held" is inexpressible.
# Mirrors upstream's nixosModules.default minus systemPackages — the package
# comes from home-manager (modules/home/handy.nix).
{
  # /dev/uinput is a systemd static node (root root 0600), so a plain
  # KERNEL=="uinput" udev rule never fires — no device-add event happens until
  # the module is loaded. hardware.uinput supplies both halves: the module load
  # and OPTIONS+="static_node=uinput".
  hardware.uinput.enable = true;

  # input  -> read /dev/input/event*   (observe key press/release)
  # uinput -> write /dev/uinput        (EVIOCGRAB clone, swallows the hotkey)
  users.users.idan.extraGroups = [ "input" "uinput" ];
}
