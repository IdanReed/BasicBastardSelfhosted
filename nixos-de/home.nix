{
  config,
  pkgs,
  lib,
  ...
}:

{
  home = {
    username = "idan";
    homeDirectory = "/home/idan";
    stateVersion = "24.11";

    sessionVariables = {
      TERMINAL = "foot";
      # Deliberately no SOPS_AGE_KEY_FILE: reading the age key should cost a
      # sudo. `sopsedit` (below) is the way in.
    };

    enableNixpkgsReleaseCheck = false;
  };

  stylix.enableReleaseChecks = false;

  programs.home-manager.enable = true;

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
        serverDir = "${config.home.homeDirectory}/local/projects/server/BasicBastardSelfhosted";
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
          nrs = "sudo nixos-rebuild switch --flake ${serverDir}#desktop";
          nrb = "sudo nixos-rebuild build --flake ${serverDir}#desktop";
          # No local sudo: the build is user-side, privilege is remote.
          "nrs-vps" = "nixos-rebuild switch --flake ${serverDir}#headscale-vps --target-host idan@vps --use-remote-sudo";
          "nrb-vps" = "nixos-rebuild build --flake ${serverDir}#headscale-vps";
          "nrs-vm" = "nixos-rebuild switch --flake ${serverDir}#services-vm --target-host idan@10.0.0.3 --use-remote-sudo";
          "nrb-vm" = "nixos-rebuild build --flake ${serverDir}#services-vm";
          # The trailing source+rehash run in the invoking shell (aliases expand
          # in place), so new aliases are usable without a new shell.
          hms = "home-manager switch --flake ${serverDir}#idan && { noctalia-shell kill 2>/dev/null || true; sleep 0.3; DISPLAY=:0 setsid -f noctalia-shell >/dev/null 2>&1; } && { source ~/.zshrc; rehash; }";
          hmb = "home-manager build --flake ${serverDir}#idan";
          # The desktop's inputs only: the root flake also pins the servers'
          # (nixos-26.05), which move deliberately, with the test harness.
          nfu = "nix flake update --flake ${serverDir} nixpkgs-unstable home-manager stylix nixvim niri noctalia noctalia-greeter zen-browser handy nixpkgs-fresh disko-unstable sops-nix-unstable";
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

    # `z` is taken by zoxide, so the detached PDF viewer is `pdf`.
    # QT_QPA_PLATFORM=xcb: sioyek's Qt-Wayland window never maps on niri.
    initContent = ''
      pdf() { QT_QPA_PLATFORM=xcb setsid -f sioyek "$@" >/dev/null 2>&1 }

      # sopsedit <file> — sops decrypts to a tmpfile, opens the editor,
      # re-encrypts on exit. Plaintext never lands in the repo.
      #
      # The key reaches sops through SOPS_AGE_KEY, not `sudo -E sops edit`,
      # so sops and the editor still run as idan (root would leave root-owned
      # droppings in ~/.config/zed). Cost: the key sits in sops' environment
      # (/proc, idan+root only) for the life of the edit.
      #
      # PREFER sopseditnvim when the edit matters: if Zed's `--wait` returns
      # instantly against a running instance (zed#54203), sops re-encrypts the
      # UNEDITED tmpfile and the edit is silently lost. `git diff` is the check.
      _sopsedit() {
        local editor=$1
        shift
        if [[ -z $1 ]]; then
          echo "usage: ''${funcstack[2]} <file.sops.yaml|.sops.json>" >&2
          return 1
        fi
        local key
        key=$(sudo cat /var/lib/sops-nix/sops_age_key.txt) || return
        SOPS_AGE_KEY=$key SOPS_EDITOR=$editor sops edit "$@"
      }
      sopsedit() { _sopsedit "zeditor --wait" "$@" }
      sopseditnvim() { _sopsedit nvim "$@" }

      # sopsgen <apply|rotate|list|view|search> [args…] — secrets-gen/sops-gen
      # from anywhere, inside its nix-shell. `--dry-run` anywhere in the args
      # skips the sudo; that pass is read-only and keyless by design.
      sopsgen() {
        local repo=${config.home.homeDirectory}/local/projects/server/BasicBastardSelfhosted
        local key=
        if [[ " $* " != *" --dry-run "* ]]; then
          key=$(sudo cat /var/lib/sops-nix/sops_age_key.txt) || return
        fi
        # (j: :) of the (q)-quoted args: ''${(q)@} alone splits like "$@" and
        # the args past the first land on nix-shell itself — --dry-run is a
        # real nix-shell flag, so the command silently never ran.
        SOPS_AGE_KEY=$key nix-shell "$repo/secrets-gen/shell.nix" \
          --run "cd $repo && secrets-gen/sops-gen ''${(j: :)''${(q)@}}"
      }

      # md2pdf <file.md> [out.pdf] — typst, not LaTeX: ~90MB of closure instead
      # of texlive's several GB. mainfont is NOT optional — pandoc hands typst
      # an empty font list without it and typst hard-errors. Libertinus Serif
      # ships inside the typst binary, so this ignores local fontconfig.
      md2pdf() {
        local in=$1
        if [[ -z $in ]]; then
          echo "usage: md2pdf <file.md> [out.pdf]" >&2
          return 1
        fi
        local out=''${2:-''${in:r}.pdf}
        nix shell nixpkgs#pandoc nixpkgs#typst -c \
          pandoc "$in" -o "$out" --pdf-engine=typst -V mainfont="Libertinus Serif"
      }

      # vidtrim <video> [speed] [threshold] [margin] — auto-editor cuts the
      # silence, ffmpeg speeds up the rest. Keeps <name>_trimmed.mp4 so a
      # re-speed skips the slow silence pass.
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
    gh
    playwright-mcp # Claude Code's browser for fleet UI setup; bundles its own Chromium
    sops
    age
    openssl # the bin output, for `openssl rand -base64 N`
    tree
    mpv
    vlc
    haruna     # clean mpv frontend (Qt): playlist panel, loads the whole folder
    celluloid  # clean mpv frontend (GTK): open a directory -> sidebar playlist
    losslesscut-bin
    gifski
    imv
    nautilus
    brightnessctl
    playerctl
    pamixer
    remmina
    freerdp
    spotify
    mpris-timer
    anki
  ];

  # nixpkgs' mpris-timer desktop entry Execs "play-timer", which it does not ship
  xdg.desktopEntries."io.github.efogdev.mpris-timer" = {
    name = "Play Timer";
    exec = "mpris-timer";
    icon = "io.github.efogdev.mpris-timer";
    terminal = false;
    categories = [ "Utility" ];
  };

  # Keep the j/k reading ruler at the screen centre: scroll as soon as it
  # passes the centre (threshold 1 = centre) and land it back there (fraction
  # 0 = centre). The defaults (0.25 / 0.75) jump most of a screen at the bottom.
  programs.sioyek = {
    enable = true;
    config = {
      visual_mark_next_page_threshold = "1.0";
      visual_mark_next_page_fraction = "0.0";
    };
  };

  # Shadows nixpkgs' sioyek.desktop so xdg-open (Zed, yazi, nautilus) gets the
  # same xcb override as the `pdf` helper — the stock entry's Qt-Wayland window
  # never maps on niri.
  xdg.desktopEntries.sioyek = {
    name = "Sioyek";
    comment = "PDF viewer for reading research papers and technical books";
    exec = "env QT_QPA_PLATFORM=xcb sioyek %f";
    icon = "sioyek-icon-linux";
    terminal = false;
    categories = [ "Development" "Viewer" ];
    mimeType = [ "application/pdf" ];
    settings.StartupWMClass = "sioyek";
  };
  xdg.mimeApps.defaultApplications."application/pdf" = [ "sioyek.desktop" ];

  # Claude Code's browser for per-app UI setup in the server workspace. Headed
  # with a persistent profile: the operator logs into Authentik (TOTP) once in
  # that window and every *.svc app's OIDC login rides the session — the agent
  # never holds the Authentik password. The workspace is not a repo, so the
  # project .mcp.json and the app-setup skill are materialised from here.
  home.file."local/projects/server/.mcp.json".text = builtins.toJSON {
    mcpServers.browser = {
      type = "stdio";
      command = "playwright-mcp";
      args = [
        "--user-data-dir"
        "${config.xdg.stateHome}/claude-browser/profile"
        "--output-dir"
        "${config.xdg.stateHome}/claude-browser/output"
      ];
    };
  };
  home.file."local/projects/server/.claude/skills/app-setup/SKILL.md".source =
    ./claude/app-setup/SKILL.md;

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
