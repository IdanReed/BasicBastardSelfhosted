# Future Considerations

Track before adding. Answer: Do I need it? How often? Already solved?

## Under Consideration

| Tool | Purpose | Priority |
|------|---------|----------|
| direnv | Per-project env | High |
| gammastep | Blue light | Medium |
| cliphist | Clipboard history | Medium |
| nvim-dap | Debugging | Medium |
| harpoon | Quick file nav | Low |

## Add On-Demand

| Category | Tools |
|----------|-------|
| Languages | Go (gopls), Zig (zls), C++ (clangd) |
| Media | OBS, GIMP, Inkscape |
| Containers | Podman, Distrobox |

## Decided Against

| Tool | Reason |
|------|--------|
| Hyprland | Niri fits scrollable workflow |
| Rofi/Polybar | X11-native |
| Eww | Overkill for status bar |
| Waybar/Mako/Fuzzel/swaybg | Replaced by Noctalia |

## Recently Added

| Date | Tool | Still Using? |
|------|------|--------------|
| Initial | Core stack | - |
| 2026-05-25 | Noctalia shell | Eval (v4 maintenance; v5 alpha upstream) |

## Process

1. Add module to `modules/home/` or `modules/nixos/`
2. Import in `flake.nix`
3. Track here
4. Review after 2 weeks
