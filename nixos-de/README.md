# NixOS Desktop

Declarative NixOS desktop: Niri + Stylix (Gruvbox) + Nixvim + CachyOS
performance tuning. This is also the fleet's admin box — every `sopsedit`,
`sopsgen`, `nrs-vm`, `nrs-vps` and `git push forgejo main` runs from here.

**Target hardware:** AMD Ryzen 7 7800X3D + NVIDIA RTX 4090

The ordered install procedure is `ServerNotes/designs/deploy-handbook.md` §19.
This file carries what is specific to this machine: the USB/Windows preparation
the handbook only summarises, the placeholders you must set, the tuning
inventory, and the keybindings.

## Stack

| Component | Choice |
|-----------|--------|
| WM | Niri |
| Theme | Stylix + Gruvbox |
| Terminal | Foot |
| Shell (bar · launcher · notifications · wallpaper · lock) | Noctalia |
| Editor | Nixvim · VS Code · Zed · Obsidian |
| File Manager | Yazi |
| Browser | Zen |
| Containers | Docker + docker-compose |

## Structure

```
nixos-de/
├── (built by the repo-root flake: .#desktop, .#idan)
├── configuration.nix            system config + CachyOS performance + nix caches
├── hardware-configuration.nix
├── disko.nix                    declarative disk partitioning (targetDisk — see below)
├── home.nix                     home-manager: aliases, sopsedit/sopsgen, starship
├── ssh-identities.nix           name → host/user/port; drives sops.secrets AND ssh config
├── secrets.sops.yaml{,.example} 14 keys: ssh/* ×7, workvpn/* ×6, SAMBA_IDAN_PASSWORD
├── test.sh / test-wsl.sh        config validation, no deploy
├── FUTURE.md                    tooling tracker
├── pkgs/                        excalirender, mmd2excalidraw, openconnect-saml
└── modules/
    ├── nixos/   containers, handy, nvidia, samba-mounts, ssh-identities,
    │            sshd, tailscale, work-vpn
    └── home/    excalidraw, foot, handy, niri, nixvim, noctalia, obsidian,
                 ssh-identities, stylix, tts, vscode, work-vpn, yazi, zed, zen
```

Desktop secrets are **`secrets.sops.yaml` (YAML)**, alongside
`secrets.sops.yaml.example` — sops-nix extracts per key only from yaml/json.

## SSH identities

`ssh-identities.nix` is the single list (name → host, user, port,
`extraOptions`). It generates both the `sops.secrets."ssh/<name>"` declarations
and the `programs.ssh` **`settings`** Host blocks — `matchBlocks` is a
deprecated alias in the pinned home-manager, and `extraOptions` entries are raw
upstream `ssh_config` directives. Each block gets
`IdentityFile /run/secrets/ssh/<name>` and `IdentitiesOnly yes`, and the Host
pattern matches both the alias and the real hostname.

Public halves live in the repo-root `ssh-pubkeys.nix`, which every host imports
(one flake for the whole repo). `gatech` and `forgejo` deliberately have
**no** `ssh-pubkeys.nix` entry — they are client identities for third-party
forges, not host authorized keys.

The first `home-manager switch` refuses to clobber a hand-written
`~/.ssh/config`; move one aside once.

## Preparing the install media

### Ventoy USB

Use **Ventoy** so all three artifacts live on one data partition (multi-ISO, no
re-flashing per release): https://www.ventoy.net/en/doc_start.html. Install
Ventoy onto the USB once, then drop these onto its data partition:

| File | Source |
|------|--------|
| `nixos-minimal-*.iso` | https://nixos.org/download/#nixos-iso |
| `BasicBastardSelfhosted.tar` | `git archive` snapshot of the repo |
| `sops_age_key.txt` | the homelab age private key |

```bash
USB=/e   # your Ventoy data partition
git archive --format=tar -o "$USB/BasicBastardSelfhosted.tar" HEAD
```

`git archive` gives LF line endings and omits `.git/` and uncommitted changes.
Boot the USB and pick the NixOS ISO from Ventoy's menu; if the live system fails
to find the ISO mount, press `Ctrl-R` for GRUB2 boot mode. **Remove the USB after
install** so the age key lives only on the target disk.

*Fallback (no Ventoy, wipes the USB):*
`dd if=nixos-minimal-*.iso of=/dev/sdX bs=4M status=progress`, or Rufus/Etcher on
Windows — then you need a second transport for the archive and the key.

### Tag the target drive from Windows, before booting the installer

With multiple identical drives, model and size do not distinguish them. Add a
small labelled partition so the target is unmistakable in the live ISO.

Disk Management (`Win+X` → Disk Management):

1. Find the target physical disk in the lower pane (confirm by size + disk number).
2. Right-click any partition on it → **Shrink Volume…** → `1024` MB → **Shrink**.
   (If the drive's contents are disposable, **Delete Volume…** instead.)
3. Right-click the **Unallocated** block → **New Simple Volume…** → Next.
4. Size: max → Next.
5. **Do not assign a drive letter or path** → Next.
6. Format **exFAT**, label `NIXOS-INSTALL`, quick format → Finish.

```powershell
Get-Volume | Where-Object FileSystemLabel -eq 'NIXOS-INSTALL'
```

disko wipes the whole disk during install, so the label is throwaway. In the live
ISO:

```bash
lsblk -o NAME,SIZE,MODEL,LABEL,SERIAL      # the disk carrying NIXOS-INSTALL is the target
ls -la /dev/disk/by-id/ | grep -v part | grep <SERIAL>
```

### `targetDisk` is deliberately unset

`disko.nix` ships:

```nix
targetDisk = "/dev/disk/by-id/CHANGE_ME_TO_YOUR_DRIVE_ID";
```

This is a **pending decision, not an oversight** — the value is machine-specific
and destructive, so the repo does not carry one. It matters only when disko
*runs*: the placeholder does not block `nix flake check`, an eval, or a
`nixos-rebuild`. Set it in the live ISO, immediately before partitioning, to the
by-id path you confirmed above.

## Placeholders to update

| File | Setting | Description |
|------|---------|-------------|
| `disko.nix` | `targetDisk` | the drive's `/dev/disk/by-id/…` path (install time only) |
| `configuration.nix` | `networking.hostName` | machine hostname |
| `configuration.nix` | `time.timeZone` | timezone |
| `home.nix` | `programs.git.settings.user.name` / `.email` | git identity |
| `modules/home/niri.nix` | `outputs` | monitor configuration (`niri msg outputs`) |

## Two things the install does not do for you

**home-manager is not installed by the system config.** `programs.home-manager.enable`
lives in `home.nix`, so the first switch has to bootstrap itself:

```bash
nix run home-manager/master -- switch \
  --flake ~/local/projects/server/BasicBastardSelfhosted/nixos-de#idan
```

After that `hms` works. The repo must live at
`~/local/projects/server/BasicBastardSelfhosted` — the `nrs`/`hms` aliases
hardcode that path.

**Nothing joins the tailnet automatically.** `modules/nixos/tailscale.nix` has no
autoconnect unit (unlike the two servers), so after the first boot:

```bash
sudo tailscale up --login-server=https://headscale.idanreed.com --accept-routes
```

That opens a browser to Authentik — log in as **`idan`**, not `akadmin`.

## Testing without deploying

```bash
./test.sh         # in WSL or on NixOS
./test-wsl.sh     # from Git Bash on Windows
```

Flake check, eval of both configs, a dry-run build of each, `statix`, and
`nixfmt`. The linters come from the flake's locked nixpkgs rather than the host,
so the gate runs the same everywhere. Run it after touching anything under
`nixos-de/`.

## Updates

```bash
sudo nixos-rebuild switch --flake .#desktop   # alias: nrs
home-manager switch --flake .#idan            # alias: hms (also restarts noctalia-shell)
nix flake update                              # alias: nfu
aliases                                       # list the shell aliases
```

`aliases` prints `shellAliases` only. `sopsedit`, `sopseditnvim` and `sopsgen`
are zsh functions defined in the same file (`home.nix`, `initContent`)
and do not appear in that listing.

## CachyOS performance optimizations

Marked with `# === CachyOS Performance ===` in the config files.

| Optimization | Location |
|--------------|----------|
| ZRAM swap (zstd, swappiness=150) | configuration.nix |
| Sysctl tuning (vm.dirty_bytes, cache pressure) | configuration.nix |
| I/O schedulers (bfq/mq-deadline/none) | configuration.nix |
| Ananicy-cpp (process priorities) | configuration.nix |
| Systemd tuning (timeouts, limits) | configuration.nix |
| NTP (Cloudflare/Google) | configuration.nix |
| NVIDIA modprobe (PAT, memory init) | modules/nixos/nvidia.nix |
| Audio power management | modules/nixos/nvidia.nix |
| VA-API hardware decode | modules/nixos/nvidia.nix |

## Key bindings

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
