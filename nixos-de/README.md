# NixOS Desktop

Declarative NixOS desktop: Niri + Stylix (Gruvbox) + Nixvim + CachyOS performance tuning.

**Target hardware:** AMD Ryzen 7 7800X3D + NVIDIA RTX 4090

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
├── configuration.nix            # System config + CachyOS performance
├── hardware-configuration.nix   # Hardware-specific settings
├── disko.nix                    # Declarative disk partitioning
├── home.nix
├── test.sh / test-wsl.sh        # Config validation
├── FUTURE.md
└── modules/
    ├── nixos/
    │   ├── nvidia.nix           # NVIDIA + CachyOS tuning
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

## Installation

### 1. Create bootable USB

Download NixOS minimal ISO and flash to USB:
```bash
# On Linux/macOS
sudo dd if=nixos-minimal-*.iso of=/dev/sdX bs=4M status=progress

# Or use Rufus/Etcher on Windows
```

### 2. Boot installer and identify target drive

```bash
# List drives with sizes and models
lsblk -d -o NAME,SIZE,MODEL

# Get stable by-id paths (includes model + serial number)
ls -la /dev/disk/by-id/ | grep -v part

# Example output:
# nvme-Samsung_SSD_990_PRO_2TB_S6Z2NF0W123456 -> ../../nvme0n1  <- NixOS target
# nvme-WD_BLACK_SN850X_1TB_12345678           -> ../../nvme1n1  <- Windows (DO NOT USE)
```

**Identify your target drive by model/size. Do NOT use the Windows drive.**

### 3. Update disko.nix with your drive

Edit `disko.nix` and set `targetDisk` to your drive's by-id path:
```nix
targetDisk = "/dev/disk/by-id/nvme-Samsung_SSD_990_PRO_2TB_S6Z2NF0W123456";
```

### 4. Clone/copy config to installer

```bash
# Connect to network
sudo systemctl start wpa_supplicant
wpa_cli  # or use nmtui

# Clone repo (or copy via USB)
nix-shell -p git
git clone https://github.com/YOUR_REPO/nixos-de /tmp/nixos-de
cd /tmp/nixos-de
```

### 5. Run disko to partition (DESTRUCTIVE)

```bash
# Preview what disko will do (safe)
sudo nix --experimental-features "nix-command flakes" run github:nix-community/disko -- --mode disko --dry-run ./disko.nix

# Actually partition the drive (DESTROYS ALL DATA ON TARGET DRIVE)
sudo nix --experimental-features "nix-command flakes" run github:nix-community/disko -- --mode disko ./disko.nix
```

### 6. Install NixOS

```bash
# Mount is automatic after disko, verify:
mount | grep /mnt

# Install
sudo nixos-install --flake .#desktop --no-root-passwd

# Set user password
sudo nixos-enter --root /mnt -c 'passwd idan'

# Reboot
sudo reboot
```

### 7. Post-install: Apply Home Manager

After first boot, login and run:
```bash
cd /path/to/nixos-de  # or clone again
home-manager switch --flake .#idan
```

### 8. Configure monitors

```bash
# Find monitor names
niri msg outputs

# Edit modules/home/niri.nix, uncomment and adjust outputs section
# Then reapply:
home-manager switch --flake .#idan
```

## Testing (Without Deploying)

Requires Nix (via WSL, NixOS, or container):

```bash
# From Git Bash on Windows
./test-wsl.sh

# Or in WSL/NixOS directly
./test.sh
```

## Updates

```bash
sudo nixos-rebuild switch --flake .#desktop  # System
home-manager switch --flake .#idan           # User
nix flake update                             # Update all inputs
```

## Placeholders to Update

| File | Setting | Description |
|------|---------|-------------|
| `disko.nix` | `targetDisk` | Your drive's `/dev/disk/by-id/...` path |
| `configuration.nix:70` | `hostName` | Machine hostname |
| `configuration.nix:75` | `timeZone` | Your timezone |
| `home.nix:77-78` | `userName`/`userEmail` | Git identity |
| `modules/home/niri.nix` | `outputs` | Monitor configuration |

## CachyOS Performance Optimizations

Performance tuning sections are marked with `# === CachyOS Performance ===` in config files.

| Optimization | Location |
|--------------|----------|
| ZRAM swap (zstd, swappiness=150) | configuration.nix |
| Sysctl tuning (vm.dirty_bytes, cache pressure) | configuration.nix |
| I/O schedulers (bfq/mq-deadline/none) | configuration.nix |
| Ananicy-cpp (process priorities) | configuration.nix |
| Systemd tuning (timeouts, limits) | configuration.nix |
| NTP (Cloudflare/Google) | configuration.nix |
| NVIDIA modprobe (PAT, memory init) | nvidia.nix |
| Audio power management | nvidia.nix |
| VA-API hardware decode | nvidia.nix |

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
