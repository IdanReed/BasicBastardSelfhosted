{ config, pkgs, lib, ... }:

# Ctrl+Shift+Space speaks the highlighted text (primary selection) through
# Piper TTS; pressing it again while speaking stops playback. The counterpart
# to Handy's Ctrl+Space speech-to-text (modules/home/handy.nix).

let
  # Voice is swappable: browse samples at https://rhasspy.github.io/piper-samples/
  # then update the four fields below (nix-prefetch-url both files for the
  # hashes). `sampleRate` must match "sample_rate" in the voice's .onnx.json —
  # medium/high voices are 22050, low voices 16000; a mismatch plays audio
  # pitched/sped wrong, it does not error.
  voice = {
    name = "en_US-lessac-medium";
    urlBase = "https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/en/en_US/lessac/medium";
    modelSha256 = "17q1mzm6xd5i2rxx2xwqkxvfx796kmp1lvk4mwkph602k7k0kzjy";
    configSha256 = "184hnvd8389xpdm0x2w6phss23v5pb34i0lhd4nmy1gdgd0rrqgg";
    sampleRate = 22050;
  };

  # Playback speed multiplier; piper expresses it inversely as length-scale.
  speed = 1.5;
  lengthScale = 1.0 / speed;

  # piper 1.4.x ignores -c/--config and always looks for <model>.onnx.json
  # next to the model, so the two fetched files must share a directory.
  voiceDir = pkgs.linkFarm "piper-voice-${voice.name}" [
    {
      name = "${voice.name}.onnx";
      path = pkgs.fetchurl {
        url = "${voice.urlBase}/${voice.name}.onnx";
        sha256 = voice.modelSha256;
      };
    }
    {
      name = "${voice.name}.onnx.json";
      path = pkgs.fetchurl {
        url = "${voice.urlBase}/${voice.name}.onnx.json";
        sha256 = voice.configSha256;
      };
    }
  ];

  speakSelection = pkgs.writeShellApplication {
    name = "speak-selection";
    runtimeInputs = [
      pkgs.wl-clipboard # wl-paste
      pkgs.piper-tts
      pkgs.pipewire # pw-play
    ];
    text = ''
      pidfile="''${XDG_RUNTIME_DIR:-/tmp}/speak-selection.pid"

      # Toggle: a second press while speaking stops playback instead of
      # layering a new voice over it.
      if [ -e "$pidfile" ]; then
        pgid="$(cat "$pidfile" 2>/dev/null || true)"
        rm -f "$pidfile"
        if [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null; then
          kill -TERM -- "-$pgid" 2>/dev/null || true
          exit 0
        fi
      fi

      # Primary selection = whatever is currently highlighted, no Ctrl+C needed.
      text="$(wl-paste --primary --no-newline 2>/dev/null || true)"
      [ -n "$text" ] || exit 0

      # --output-raw streams audio as sentences finish, so long selections
      # start speaking immediately. setsid gives the pipeline its own process
      # group so the stop path above can kill piper and pw-play together.
      # shellcheck disable=SC2016 # inner $1 is expanded by the inner sh, on purpose
      setsid sh -c '
        printf "%s\n" "$1" \
          | piper --model ${voiceDir}/${voice.name}.onnx \
              --length-scale ${toString lengthScale} --output-raw 2>/dev/null \
          | pw-play --raw --rate ${toString voice.sampleRate} \
              --channels 1 --format s16 -
      ' _ "$text" &
      pgid=$!
      printf '%s\n' "$pgid" >"$pidfile"
      wait "$pgid" || true
      rm -f "$pidfile"
    '';
  };
in
{
  # On PATH so `speak-selection` also works from a shell.
  home.packages = [ speakSelection ];

  # Store path rather than bare name: niri's spawn environment does not
  # reliably include the home-manager profile PATH under greetd.
  programs.niri.settings.binds."Ctrl+Shift+Space" = {
    action.spawn = [ (lib.getExe speakSelection) ];
    hotkey-overlay.title = "Speak selection / stop speaking (TTS)";
  };
}
