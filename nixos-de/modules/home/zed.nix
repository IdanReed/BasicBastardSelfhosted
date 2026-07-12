{ config, pkgs, ... }:

{
  programs.zed-editor = {
    enable = true;

    extensions = [
      "git-firefly"
      "nix"
      "toml"
      "kdl"
      "dockerfile"
      "docker-compose"
      "lua"
      "make"
      "just"
      "html"
      "scss"
      "markdown-oxide"
    ];

    userSettings = {
      load_direnv = "shell_hook";

      languages = {
        Nix = {
          language_servers = [ "nixd" "!nil" ];
        };
        Python = {
          language_servers = [ "ruff" "pyright" ];
        };
      };

      lsp = {
        nixd = {
          binary = {
            path = "${pkgs.nixd}/bin/nixd";
          };
        };
        nil = {
          binary = {
            path = "${pkgs.nil}/bin/nil";
          };
        };
        ruff = {
          binary = {
            path = "${pkgs.ruff}/bin/ruff";
            arguments = [ "server" ];
          };
        };
      };
    };
  };
}
