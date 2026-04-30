{ config, pkgs, ... }:

{
  programs.yazi = {
    enable = true;
    enableZshIntegration = true;

    settings = {
      manager = {
        ratio = [ 1 4 3 ];
        sort_by = "natural";
        sort_sensitive = false;
        sort_reverse = false;
        sort_dir_first = true;
        show_hidden = false;
        show_symlink = true;
        linemode = "size";
      };

      preview = {
        tab_size = 2;
        max_width = 600;
        max_height = 900;
        image_filter = "triangle";
        image_quality = 75;
        sixel_fraction = 15;
      };

      opener = {
        edit = [{ run = "nvim \"$@\""; block = true; }];
        open = [{ run = "xdg-open \"$@\""; orphan = true; }];
        extract = [{ run = "unar \"$1\""; desc = "Extract here"; }];
        play = [{ run = "mpv \"$@\""; orphan = true; }];
      };

      open.rules = [
        { mime = "text/*"; use = "edit"; }
        { mime = "image/*"; use = "open"; }
        { mime = "video/*"; use = "play"; }
        { mime = "audio/*"; use = "play"; }
        { mime = "application/json"; use = "edit"; }
        { mime = "application/pdf"; use = "open"; }
      ];
    };

    keymap = {
      manager.prepend_keymap = [
        { on = [ "<Enter>" ]; run = "open"; desc = "Open"; }
        { on = [ "e" ]; run = "open --interactive"; desc = "Edit"; }

        { on = [ "h" ]; run = "leave"; desc = "Parent"; }
        { on = [ "l" ]; run = "enter"; desc = "Enter"; }
        { on = [ "j" ]; run = "arrow 1"; desc = "Down"; }
        { on = [ "k" ]; run = "arrow -1"; desc = "Up"; }
        { on = [ "g" "g" ]; run = "arrow -99999999"; desc = "Top"; }
        { on = [ "G" ]; run = "arrow 99999999"; desc = "Bottom"; }

        { on = [ "<Space>" ]; run = [ "select --state=none" "arrow 1" ]; desc = "Toggle select"; }
        { on = [ "v" ]; run = "visual_mode"; desc = "Visual mode"; }

        { on = [ "y" ]; run = "yank"; desc = "Yank"; }
        { on = [ "x" ]; run = "yank --cut"; desc = "Cut"; }
        { on = [ "p" ]; run = "paste"; desc = "Paste"; }
        { on = [ "d" ]; run = "remove"; desc = "Delete"; }
        { on = [ "D" ]; run = "remove --permanently"; desc = "Delete permanently"; }

        { on = [ "a" ]; run = "create"; desc = "Create"; }
        { on = [ "r" ]; run = "rename --cursor=before_ext"; desc = "Rename"; }

        { on = [ "/" ]; run = "search fd"; desc = "Search"; }
        { on = [ "." ]; run = "hidden toggle"; desc = "Toggle hidden"; }
        { on = [ "q" ]; run = "quit"; desc = "Quit"; }
      ];
    };
  };

  home.packages = with pkgs; [ unar ffmpegthumbnailer poppler_utils fd ripgrep ];
}
