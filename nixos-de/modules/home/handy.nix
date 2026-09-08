{ config, pkgs, lib, inputs, ... }:

let
  handy = inputs.handy.packages.${pkgs.stdenv.hostPlatform.system}.handy;

  # Handy's fallback (enigo) does not work under a pure-Wayland compositor.
  wlTools = [ pkgs.wtype pkgs.wl-clipboard ];
in
{
  services.handy = {
    enable = true;
    package = handy;
  };

  home.packages = [ handy ] ++ wlTools;

  systemd.user.services.handy.Service = {
    # Upstream's module starts the GUI window; we want the tray only.
    ExecStart = lib.mkForce "${lib.getExe handy} --start-hidden";
    # The user manager's PATH is not reliably populated by the time
    # graphical-session.target comes up under greetd.
    Environment = [
      "PATH=${lib.makeBinPath wlTools}:${config.home.profileDirectory}/bin:/run/current-system/sw/bin"
    ];
  };

  # No niri bind for the record key: a bind fires only on press, and niri has no
  # on-release property, so push-to-talk is inexpressible. Handy owns Ctrl+Space
  # itself via its evdev backend (permissions: modules/nixos/handy.nix).
  #
  # ONE-TIME MANUAL STEP — the backend lives in Handy's own settings_store.json,
  # which the app rewrites, so it cannot be set here. Settings > Advanced, turn
  # ON "Experimental", then Keyboard Implementation -> "Handy Keys". Confirm:
  #   jq '.settings.keyboard_implementation' \
  #     ~/.local/share/com.pais.handy/settings_store.json     # -> "handy_keys"
  # While it reads "tauri" the binding silently loses Ctrl+Space to whatever
  # else holds it ("register_tauri_shortcut duplicate error" in handy.log).
}
