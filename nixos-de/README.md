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
| Editor | Nixvim · VS Code · Zed |
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
├── .sops.env.example            # SOPS secret template (encrypt copy as .sops.env)
└── modules/
    ├── nixos/
    │   ├── nvidia.nix           # NVIDIA + CachyOS tuning
    │   ├── stylix.nix
    │   ├── tailscale.nix        # Tailscale client (run `tailscale up` after install)
    │   └── sops.nix             # sops-nix wiring (shared age key)
    └── home/
        ├── niri.nix
        ├── stylix.nix
        ├── nixvim.nix
        ├── foot.nix
        ├── fuzzel.nix
        ├── yazi.nix
        ├── waybar.nix
        ├── mako.nix
        ├── zen.nix
        ├── vscode.nix
        └── zed.nix
```

## Installation

### 1. Create bootable USB

Download the NixOS minimal ISO from https://nixos.org/download/#nixos-iso.

**Recommended: Ventoy** (multi-ISO, no re-flashing per release)

1. Install Ventoy onto the USB once — https://www.ventoy.net/en/doc_start.html (Windows GUI or `Ventoy2Disk.sh` on Linux).
2. Copy `nixos-minimal-*.iso` onto the USB's data partition as a regular file.
3. Copy `sops_age_key.txt` (the homelab age private key) onto the same data partition — it will be injected during install in step 6. Remove the USB after install so the key only lives on the target disk.
4. Boot the USB and pick the ISO from Ventoy's menu.

If the live system fails to find the ISO mount, press `Ctrl-R` in the Ventoy menu to switch to GRUB2 boot mode.

**Fallback: direct flash** (single ISO, wipes the USB)

```bash
# On Linux/macOS
sudo dd if=nixos-minimal-*.iso of=/dev/sdX bs=4M status=progress

# Or use Rufus/Etcher on Windows
```

### 2. Tag the target drive from Windows (do this before booting the installer)

If you have multiple identical drives, model/size won't distinguish them. Add a small labeled partition from Windows so the target is unmistakable in the live ISO.

In **Disk Management** (`Win+X` → Disk Management):

1. Find the target physical disk in the lower pane (confirm by size + disk number).
2. Right-click any existing partition on that drive → **Shrink Volume…** → enter `1024` MB → **Shrink**. (Or if the drive's contents are disposable, **Delete Volume…** instead.)
3. Right-click the resulting **Unallocated** block → **New Simple Volume…** → Next.
4. Size: leave at max → Next.
5. **Do not assign a drive letter or path** → Next.
6. Format: **exFAT**, volume label `NIXOS-INSTALL`, quick format → Next → Finish.

Verify in PowerShell:
```powershell
Get-Volume | Where-Object FileSystemLabel -eq 'NIXOS-INSTALL'
```

disko wipes the entire disk during install, so the label is throwaway.

### 3. Boot installer and identify target drive

```bash
# The labeled partition makes the target unambiguous
lsblk -o NAME,SIZE,MODEL,LABEL,SERIAL

# Example output (target = the disk containing the NIXOS-INSTALL partition):
# nvme0n1     2T  Samsung SSD 990 PRO 2TB                  S6Z2NF0W123456
# ├─nvme0n1p1 1G                          NIXOS-INSTALL    <- target marker
# └─nvme0n1p2 1.9T                        Data
# nvme1n1     2T  Samsung SSD 990 PRO 2TB                  S6Z2NF0WABCDEF
# └─nvme1n1p1 2T                          Windows          <- DO NOT USE

# Get the stable by-id path for the target disk
ls -la /dev/disk/by-id/ | grep -v part | grep <SERIAL>
```

**Confirm the target by the `NIXOS-INSTALL` label. Do NOT use the Windows drive.**

### 4. Update disko.nix with your drive

Edit `disko.nix` and set `targetDisk` to your drive's by-id path:
```nix
targetDisk = "/dev/disk/by-id/nvme-Samsung_SSD_990_PRO_2TB_S6Z2NF0W123456";
```

### 5. Clone/copy config to installer

```bash
# Connect to network
sudo systemctl start wpa_supplicant
wpa_cli  # or use nmtui

# Clone repo (or copy via USB)
nix-shell -p git
git clone https://github.com/YOUR_REPO/nixos-de /tmp/nixos-de
cd /tmp/nixos-de
```

### 6. Run disko to partition (DESTRUCTIVE)

```bash
# Preview what disko will do (safe)
sudo nix --experimental-features "nix-command flakes" run github:nix-community/disko -- --mode disko --dry-run ./disko.nix

# Actually partition the drive (DESTROYS ALL DATA ON TARGET DRIVE)
sudo nix --experimental-features "nix-command flakes" run github:nix-community/disko -- --mode disko ./disko.nix
```

### 7. Inject the SOPS age key

The desktop uses the same age key as the rest of the homelab (server VM, VPS, Windows workstation). Copy `sops_age_key.txt` from the Ventoy USB data partition into the target system before installing:

```bash
# Locate the USB data partition (Ventoy mounts it under /run/media/...)
lsblk -o NAME,LABEL,MOUNTPOINT
USB=/run/media/<user>/<ventoy-label>   # adjust

sudo mkdir -p -m 700 /mnt/var/lib/sops-nix
sudo cp "$USB/sops_age_key.txt" /mnt/var/lib/sops-nix/sops_age_key.txt
sudo chmod 600 /mnt/var/lib/sops-nix/sops_age_key.txt
sudo chown 0:0 /mnt/var/lib/sops-nix/sops_age_key.txt
```

If you'd rather not put the key on the USB, paste it from your password manager:
```bash
sudo install -m 700 -d /mnt/var/lib/sops-nix
sudo install -m 600 /dev/stdin /mnt/var/lib/sops-nix/sops_age_key.txt <<'EOF'
AGE-SECRET-KEY-...
EOF
```

### 8. Install NixOS

```bash
# Mount is automatic after disko, verify:
mount | grep /mnt

# Install
sudo nixos-install --flake .#desktop --no-root-passwd

# Set user password (skip if USER_PASSWORD_HASH is wired up in .sops.env)
sudo nixos-enter --root /mnt -c 'passwd idan'

# Reboot (remove the USB)
sudo reboot
```

### 9. Post-install: Apply Home Manager

After first boot, login and run:
```bash
cd /path/to/nixos-de  # or clone again
home-manager switch --flake .#idan
```

### 10. Configure monitors

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

https://public-fate-bird-aware.taile6bbb.ts.net/#/vault