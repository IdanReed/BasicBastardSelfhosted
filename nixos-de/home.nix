{ config, pkgs, lib, inputs, ... }:

{
  home = {
    username = "idan";
    homeDirectory = "/home/idan";
    stateVersion = "24.11";

    sessionVariables = {
      TERMINAL = "foot";
    };
  };

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

    shellAliases = let
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
        hms = "home-manager switch --flake ${flakeDir}#idan";
        hmb = "home-manager build --flake ${flakeDir}#idan";
        nfu = "nix flake update";
        ngc = "sudo nix-collect-garbage -d";
      };
      # Right-pad names so the arrows line up.
      maxName = lib.foldl' lib.max 0 (map lib.stringLength (lib.attrNames myAliases ++ [ "aliases" ]));
      rpad = s: s + lib.concatStrings (lib.genList (_: " ") (maxName - lib.stringLength s));
      aliasHelp = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (n: v: "  ${rpad n} → ${v}")
          (myAliases // { aliases = "show this list"; })
      );
    in myAliases // {
      aliases = "echo ${lib.escapeShellArg aliasHelp}";
    };
    # Note: greetd handles session startup, no TTY auto-login needed
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
    nodejs python3 rustup
    eza bat fzf zoxide lazygit tree
    mpv imv
    brightnessctl playerctl pamixer
  ];

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
