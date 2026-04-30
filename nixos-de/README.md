# NixOS Desktop

Declarative NixOS desktop: Niri + Stylix (Gruvbox) + Nixvim

## Stack

| Component | Choice |
|-----------|--------|
| WM | Niri |
| Theme | Stylix + Gruvbox |
| Terminal | Foot |
| Launcher | Fuzzel |
| Bar | Waybar |
| Notifications | Mako |
| Editor | Nixvim |
| File Manager | Yazi |
| Browser | Zen |

## Structure

```
nixos-de/
├── flake.nix
├── configuration.nix
├── hardware-configuration.nix  # Generate on target
├── home.nix
├── FUTURE.md
└── modules/
    ├── nixos/
    │   ├── nvidia.nix
    │   └── stylix.nix
    └── home/
        ├── niri.nix
        ├── stylix.nix
        ├── nixvim.nix
        ├── foot.nix
        ├── fuzzel.nix
        ├── yazi.nix
        ├── waybar.nix
        ├── mako.nix
        └── zen.nix
```

## Deployment

```bash
# Generate hardware config on target
nixos-generate-config --show-hardware-config > hardware-configuration.nix

# Install NixOS
nixos-install --flake .#desktop

# After reboot, apply Home Manager (as user)
home-manager switch --flake .#idan
```

## Updates

```bash
sudo nixos-rebuild switch --flake .#desktop  # System
home-manager switch --flake .#idan           # User
```

## Key Bindings

### Niri

| Key | Action |
|-----|--------|
| `Mod+Return` | Terminal |
| `Mod+D` | Launcher |
| `Mod+B` | Browser |
| `Mod+E` | File manager |
| `Mod+Q` | Close window |
| `Mod+H/J/K/L` | Focus |
| `Mod+Shift+H/J/K/L` | Move |
| `Mod+1-5` | Workspace |
| `Mod+F` | Maximize |
| `Mod+Shift+F` | Fullscreen |
| `Mod+Shift+E` | Quit |

### Neovim

| Key | Action |
|-----|--------|
| `Space` | Leader |
| `<leader>ff` | Find files |
| `<leader>fg` | Live grep |
| `<leader>e` | File tree |
| `gd` | Go to definition |
| `K` | Hover |
| `<leader>gg` | LazyGit |

## Monitor Setup

Edit `modules/home/niri.nix`:
```nix
outputs = {
  "DP-1" = { scale = 1.5; position = { x = 0; y = 0; }; };
  "DP-2" = { scale = 1.0; position = { x = 2560; y = 0; }; };
};
```
Find names: `niri msg outputs`
