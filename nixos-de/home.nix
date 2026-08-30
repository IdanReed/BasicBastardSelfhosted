{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:

{
  home = {
    username = "idan";
    homeDirectory = "/home/idan";
    stateVersion = "24.11";

    sessionVariables = {
      TERMINAL = "foot";
      # Deliberately no SOPS_AGE_KEY_FILE: the only copy of the age key on this
      # box is /var/lib/sops-nix/sops_age_key.txt, 0700 root, and it stays that
      # way — reading it should cost a sudo. `sopsedit` (below) is the way in.
    };

    enableNixpkgsReleaseCheck = false;
  };

  stylix.enableReleaseChecks = false;

  programs.home-manager.enable = true;

  wayland.windowManager.hyprland.configType = "hyprlang";

  xdg = {
    enable = true;
    userDirs = {
      enable = true;
      createDirectories = true;
      setSessionVariables = true;
      download = "${config.home.homeDirectory}/local/downloads";
      desktop = "${config.home.homeDirectory}/user_dirs/desktop";
      documents = "${config.home.homeDirectory}/user_dirs/documents";
      music = "${config.home.homeDirectory}/user_dirs/music";
      pictures = "${config.home.homeDirectory}/user_dirs/pictures";
      videos = "${config.home.homeDirectory}/user_dirs/videos";
      projects = "${config.home.homeDirectory}/user_dirs/projects";
      publicShare = "${config.home.homeDirectory}/user_dirs/public";
      templates = "${config.home.homeDirectory}/user_dirs/templates";
    };
  };

  programs.zsh = {
    enable = true;
    dotDir = config.home.homeDirectory;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;
    enableCompletion = true;

    history = {
      size = 10000;
      save = 10000;
      ignoreDups = true;
      ignoreSpace = true;
      share = true;
    };

    shellAliases =
      let
        flakeDir = "${config.home.homeDirectory}/local/projects/server/BasicBastardSelfhosted/nixos-de";
        myAliases = {
          ".." = "cd ..";
          "..." = "cd ../..";
          g = "git";
          gs = "git status";
          gd = "git diff";
          gl = "git log --oneline -20";
          lg = "lazygit";
          v = "nvim";
          zed = "zeditor";
          nrs = "sudo nixos-rebuild switch --flake ${flakeDir}#desktop";
          nrb = "sudo nixos-rebuild build --flake ${flakeDir}#desktop";
          hms = "home-manager switch --flake ${flakeDir}#idan && { noctalia-shell kill 2>/dev/null || true; sleep 0.3; DISPLAY=:0 setsid -f noctalia-shell >/dev/null 2>&1; }";
          hmb = "home-manager build --flake ${flakeDir}#idan";
          nfu = "nix flake update";
          ngc = "sudo nix-collect-garbage -d";
          ccupdate = "nix profile upgrade claude-code-nix";
        };
        # Right-pad names so the arrows line up.
        maxName = lib.foldl' lib.max 0 (map lib.stringLength (lib.attrNames myAliases ++ [ "aliases" ]));
        rpad = s: s + lib.concatStrings (lib.genList (_: " ") (maxName - lib.stringLength s));
        aliasHelp = lib.concatStringsSep "\n" (
          lib.mapAttrsToList (n: v: "  ${rpad n} → ${v}") (myAliases // { aliases = "show this list"; })
        );
      in
      myAliases
      // {
        aliases = "echo ${lib.escapeShellArg aliasHelp}";
      };
    # Note: greetd handles session startup, no TTY auto-login needed

    # `z` is taken by zoxide, so the detached-viewer helper is `pdf`.
    # QT_QPA_PLATFORM=xcb: sioyek's Qt-Wayland window never maps on niri;
    # running it through xwayland-satellite works.
    initContent = ''
      pdf() { QT_QPA_PLATFORM=xcb setsid -f sioyek "$@" >/dev/null 2>&1 }

      # sopsedit <file> — edit a sops file in Zed.
      #
      # Zed has no SOPS extension: zed-industries/extensions#3004 is blocked on
      # the extension API having no buffer open/save hook, so transparent
      # decrypt-on-open is not buildable. Go the other way instead — sops
      # decrypts to a tmpfile, spawns Zed on it, re-encrypts when Zed exits.
      # Plaintext never lands in the repo.
      #
      # The age key is root-only (/var/lib/sops-nix, 0700), which is the point:
      # each edit costs a sudo. `sudo cat` reads it, and it reaches sops through
      # SOPS_AGE_KEY so that sops and Zed still run as idan — `sudo -E sops
      # edit` would spawn the editor as root and leave root-owned droppings in
      # ~/.config/zed. Cost of that choice: the key sits in sops' environment
      # (readable via /proc by idan and root only) for the life of the edit.
      #
      # If `--wait` ever returns instantly against an already-running Zed
      # (zed-industries/zed#54203), sops re-encrypts the *unedited* tmpfile and
      # the edit is silently lost — `git diff` after saving is the check.
      sopsedit() {
        if [[ -z $1 ]]; then
          echo "usage: sopsedit <file.sops.yaml|.sops.env>" >&2
          return 1
        fi
        local key
        key=$(sudo cat /var/lib/sops-nix/sops_age_key.txt) || return
        SOPS_AGE_KEY=$key SOPS_EDITOR="zeditor --wait" sops edit "$@"
      }

      # vidtrim <video> [speed] [threshold] [margin]
      # auto-editor cuts the silence, ffmpeg speeds up what's left.
      # Leaves <name>_trimmed.mp4 next to <name>_x<speed>.mp4 so you can
      # re-speed without re-running the (slow) silence pass.
      vidtrim() {
        local in=$1 speed=''${2:-1.5} threshold=''${3:-8%} margin=''${4:-0.06s}
        if [[ -z $in ]]; then
          echo "usage: vidtrim <video> [speed=1.5] [threshold=8%] [margin=0.06s]" >&2
          return 1
        fi
        local trimmed=''${in:r}_trimmed.mp4 out=''${in:r}_x''${speed}.mp4
        nix shell nixpkgs#auto-editor nixpkgs#ffmpeg -c bash -c '
          set -e
          auto-editor "$1" --edit audio:threshold="$3" --margin "$4" -o "$5"
          ffmpeg -i "$5" \
            -filter_complex "[0:v]setpts=PTS/$2[v];[0:a]atempo=$2[a]" \
            -map "[v]" -map "[a]" "$6"
        ' vidtrim "$in" "$speed" "$threshold" "$margin" "$trimmed" "$out"
      }
    '';
  };

  programs.starship = {
    enable = true;
    enableZshIntegration = true;
    settings = {
      add_newline = false;
      format = "$directory$git_branch$git_status$character";
      character = {
        success_symbol = "[➜](bold green)";
        error_symbol = "[✗](bold red)";
      };
      directory = {
        truncation_length = 3;
        truncate_to_repo = true;
      };
    };
  };

  programs.git = {
    enable = true;
    settings = {
      user.name = "Idan Reed";
      user.email = "idan@idanreed.com";
      init.defaultBranch = "main";
      pull.rebase = true;
      push.autoSetupRemote = true;
      core.editor = "nvim";
    };
  };

  programs.delta = {
    enable = true;
    enableGitIntegration = true;
    options = {
      navigate = true;
      line-numbers = true;
      syntax-theme = "gruvbox-dark";
    };
  };

  home.packages = with pkgs; [
    nodejs
    python3
    uv
    rustc
    cargo
    rustfmt
    clippy
    rust-analyzer
    eza
    bat
    fzf
    zoxide
    lazygit
    gh # GitHub CLI — PRs, Actions runs, releases
    sops
    age
    tree
    mpv
    losslesscut-bin
    gifski  # video -> gif, e.g. gifski -o out.gif --fps 15 --width 800 in.mp4
    imv
    nautilus
    brightnessctl
    playerctl
    pamixer
    remmina
    freerdp
    spotify
    sioyek
    mpris-timer  # focus/countdown timer (Hourglass-like), integrates with MPRIS widgets
    #networkmanagerapplet  # provides nm-connection-editor for VPN setup
  ];

  # nixpkgs' mpris-timer desktop entry Execs "play-timer", a binary the package doesn't ship
  xdg.desktopEntries."io.github.efogdev.mpris-timer" = {
    name = "Play Timer";
    exec = "mpris-timer";
    icon = "io.github.efogdev.mpris-timer";
    terminal = false;
    categories = [ "Utility" ];
  };

  programs.obs-studio = {
    enable = true;
    plugins = with pkgs.obs-studio-plugins; [
      obs-pipewire-audio-capture
    ];
  };

  programs.fzf = {
    enable = true;
    enableZshIntegration = true;
  };

  programs.zoxide = {
    enable = true;
    enableZshIntegration = true;
  };

  programs.eza = {
    enable = true;
    enableZshIntegration = true;
    git = true;
    icons = "auto";
  };
}
