{ config, pkgs, lib, inputs, ... }:

let
  handy = inputs.handy.packages.${pkgs.stdenv.hostPlatform.system}.handy;

  # wtype injects the transcribed text as keystrokes and wl-copy backs the
  # clipboard-paste path. Without them Handy falls back to enigo, which does
  # not work under a pure-Wayland compositor.
  wlTools = [ pkgs.wtype pkgs.wl-clipboard ];
in
{
  services.handy = {
    enable = true;
    package = handy;
  };

  # On PATH so the app shows up in the launcher and `handy` works from a shell.
  home.packages = [ handy ] ++ wlTools;

  systemd.user.services.handy.Service = {
    # Upstream's module starts the GUI window; we want the tray only.
    ExecStart = lib.mkForce "${lib.getExe handy} --start-hidden";
    # The user manager's PATH is not reliably populated by the time
    # graphical-session.target comes up under greetd, so spell it out.
    Environment = [
      "PATH=${lib.makeBinPath wlTools}:${config.home.profileDirectory}/bin:/run/current-system/sw/bin"
    ];
  };

  # No niri bind for the record key. A bind can only fire on press, so the best
  # it can do is `handy --toggle-transcription` — press to start, press again
  # to stop. Push-to-talk needs the key release too, which niri has no way to
  # express (its bind properties are allow-inhibiting, allow-when-locked,
  # cooldown-ms, hotkey-overlay-title, repeat — no on-release).
  #
  # So Handy owns Ctrl+Space itself, via its evdev backend. That path does
  # report release, and Handy already has push_to_talk enabled, so holding the
  # key records and letting go transcribes. See modules/nixos/handy.nix for the
  # permissions it needs, and switch Settings > Advanced > Experimental >
  # Keyboard Implementation to "Handy Keys" to select it.
}
