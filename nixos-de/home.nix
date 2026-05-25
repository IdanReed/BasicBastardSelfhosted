{ config, pkgs, inputs, ... }:

{
  home = {
    username = "idan";
    homeDirectory = "/home/idan";
    stateVersion = "24.11";
  };

  programs.home-manager.enable = true;

  wayland.windowManager.hyprland.configType = "hyprlang";

  xdg = {
    enable = true;
    userDirs = {
      enable = true;
      createDirectories = true;
      setSessionVariables = true;
      desktop = "${config.home.homeDirectory}/desktop";
      documents = "${config.home.homeDirectory}/documents";
      download = "${config.home.homeDirectory}/downloads";
      music = "${config.home.homeDirectory}/music";
      pictures = "${config.home.homeDirectory}/pictures";
      videos = "${config.home.homeDirectory}/videos";
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

    shellAliases = {
      ll = "ls -la";
      la = "ls -A";
      ".." = "cd ..";
      "..." = "cd ../..";
      g = "git";
      v = "nvim";
      nrs = "sudo nixos-rebuild switch --flake .#desktop";
      hms = "home-manager switch --flake .#idan";
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
    inputs.zen-browser.packages.${pkgs.stdenv.hostPlatform.system}.default
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
