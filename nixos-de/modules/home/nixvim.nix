{ config, pkgs, ... }:

{
  programs.nixvim = {
    enable = true;
    defaultEditor = true;

    opts = {
      number = true;
      relativenumber = true;
      tabstop = 2;
      shiftwidth = 2;
      softtabstop = 2;
      expandtab = true;
      smartindent = true;
      ignorecase = true;
      smartcase = true;
      hlsearch = true;
      incsearch = true;
      termguicolors = true;
      signcolumn = "yes";
      cursorline = true;
      scrolloff = 8;
      wrap = false;
      showmode = false;
      swapfile = false;
      backup = false;
      undofile = true;
      splitbelow = true;
      splitright = true;
      completeopt = [ "menu" "menuone" "noselect" ];
      updatetime = 250;
      timeoutlen = 300;
      mouse = "a";
      clipboard = "unnamedplus";
    };

    globals = {
      mapleader = " ";
      maplocalleader = " ";
    };

    keymaps = [
      { mode = "i"; key = "jk"; action = "<Esc>"; }
      { mode = "n"; key = "<leader>w"; action = "<cmd>w<CR>"; }
      { mode = "n"; key = "<leader>q"; action = "<cmd>q<CR>"; }
      { mode = "n"; key = "<Esc>"; action = "<cmd>noh<CR>"; }

      { mode = "n"; key = "<C-h>"; action = "<C-w>h"; }
      { mode = "n"; key = "<C-j>"; action = "<C-w>j"; }
      { mode = "n"; key = "<C-k>"; action = "<C-w>k"; }
      { mode = "n"; key = "<C-l>"; action = "<C-w>l"; }

      { mode = "n"; key = "<S-h>"; action = "<cmd>bprevious<CR>"; }
      { mode = "n"; key = "<S-l>"; action = "<cmd>bnext<CR>"; }
      { mode = "n"; key = "<leader>bd"; action = "<cmd>bdelete<CR>"; }

      { mode = "v"; key = "J"; action = ":m '>+1<CR>gv=gv"; }
      { mode = "v"; key = "K"; action = ":m '<-2<CR>gv=gv"; }
      { mode = "v"; key = "<"; action = "<gv"; }
      { mode = "v"; key = ">"; action = ">gv"; }

      { mode = "n"; key = "<leader>ff"; action = "<cmd>Telescope find_files<CR>"; }
      { mode = "n"; key = "<leader>fg"; action = "<cmd>Telescope live_grep<CR>"; }
      { mode = "n"; key = "<leader>fb"; action = "<cmd>Telescope buffers<CR>"; }
      { mode = "n"; key = "<leader>fh"; action = "<cmd>Telescope help_tags<CR>"; }
      { mode = "n"; key = "<leader>fr"; action = "<cmd>Telescope oldfiles<CR>"; }

      { mode = "n"; key = "<leader>e"; action = "<cmd>Neotree toggle<CR>"; }

      { mode = "n"; key = "gd"; action = "<cmd>lua vim.lsp.buf.definition()<CR>"; }
      { mode = "n"; key = "gr"; action = "<cmd>lua vim.lsp.buf.references()<CR>"; }
      { mode = "n"; key = "K"; action = "<cmd>lua vim.lsp.buf.hover()<CR>"; }
      { mode = "n"; key = "<leader>ca"; action = "<cmd>lua vim.lsp.buf.code_action()<CR>"; }
      { mode = "n"; key = "<leader>rn"; action = "<cmd>lua vim.lsp.buf.rename()<CR>"; }
      { mode = "n"; key = "<leader>d"; action = "<cmd>lua vim.diagnostic.open_float()<CR>"; }
      { mode = "n"; key = "[d"; action = "<cmd>lua vim.diagnostic.goto_prev()<CR>"; }
      { mode = "n"; key = "]d"; action = "<cmd>lua vim.diagnostic.goto_next()<CR>"; }
      { mode = "n"; key = "<leader>lf"; action = "<cmd>lua vim.lsp.buf.format()<CR>"; }

      { mode = "n"; key = "<leader>gg"; action = "<cmd>LazyGit<CR>"; }
    ];

    plugins = {
      lualine = {
        enable = true;
        settings.options = {
          icons_enabled = true;
          component_separators = { left = ""; right = ""; };
          section_separators = { left = ""; right = ""; };
        };
      };

      neo-tree = {
        enable = true;
        closeIfLastWindow = true;
        window.width = 30;
      };

      which-key = {
        enable = true;
        settings.delay = 200;
      };

      indent-blankline = {
        enable = true;
        settings.scope.enabled = true;
      };

      telescope = {
        enable = true;
        extensions.fzf-native.enable = true;
        settings.defaults = {
          file_ignore_patterns = [ "node_modules" ".git/" "target/" ];
          layout_strategy = "horizontal";
        };
      };

      treesitter = {
        enable = true;
        settings = {
          highlight.enable = true;
          indent.enable = true;
          ensure_installed = [
            "bash" "c" "css" "dockerfile" "go" "html" "javascript" "json"
            "lua" "markdown" "markdown_inline" "nix" "python" "rust"
            "toml" "tsx" "typescript" "vim" "vimdoc" "yaml"
          ];
        };
      };
      treesitter-textobjects.enable = true;

      lsp = {
        enable = true;
        servers = {
          nil_ls.enable = true;
          ts_ls.enable = true;
          pyright.enable = true;
          rust_analyzer = {
            enable = true;
            installCargo = false;
            installRustc = false;
          };
          lua_ls.enable = true;
          html.enable = true;
          cssls.enable = true;
          jsonls.enable = true;
          yamlls.enable = true;
          bashls.enable = true;
        };
      };

      cmp = {
        enable = true;
        autoEnableSources = true;
        settings = {
          sources = [
            { name = "nvim_lsp"; }
            { name = "luasnip"; }
            { name = "path"; }
            { name = "buffer"; }
          ];
          mapping = {
            "<C-Space>" = "cmp.mapping.complete()";
            "<C-e>" = "cmp.mapping.abort()";
            "<CR>" = "cmp.mapping.confirm({ select = true })";
            "<Tab>" = "cmp.mapping(cmp.mapping.select_next_item(), {'i', 's'})";
            "<S-Tab>" = "cmp.mapping(cmp.mapping.select_prev_item(), {'i', 's'})";
          };
          snippet.expand = "function(args) require('luasnip').lsp_expand(args.body) end";
        };
      };

      luasnip.enable = true;
      friendly-snippets.enable = true;

      conform-nvim = {
        enable = true;
        settings = {
          format_on_save = { timeout_ms = 500; lsp_fallback = true; };
          formatters_by_ft = {
            lua = [ "stylua" ];
            python = [ "black" ];
            javascript = [ "prettier" ];
            typescript = [ "prettier" ];
            json = [ "prettier" ];
            yaml = [ "prettier" ];
            nix = [ "nixfmt" ];
            rust = [ "rustfmt" ];
          };
        };
      };

      gitsigns = {
        enable = true;
        settings.signs = {
          add = { text = "│"; };
          change = { text = "│"; };
          delete = { text = "_"; };
        };
      };

      lazygit.enable = true;
      autopairs.enable = true;
      comment.enable = true;
      todo-comments.enable = true;
      web-devicons.enable = true;
      neoscroll.enable = true;
    };

    extraPackages = with pkgs; [
      stylua black nodePackages.prettier nixfmt-classic rustfmt
      ripgrep fd
    ];
  };
}
