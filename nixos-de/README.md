# NixOS desktop

Niri + Stylix (Gruvbox) + Nixvim + CachyOS-style tuning on an AMD Ryzen 7
7800X3D / NVIDIA RTX 4090. It is also the fleet's admin box: every
`sopsedit`, `sopsgen`, `nrs-vm`, `nrs-vps` and `git push forgejo main` runs
from here.

The install is [docs/bring-up.md](../docs/bring-up.md) §19. This file carries
what is specific to this machine: the install-media preparation, the
placeholders, the tuning and the key bindings.

| Component | Choice |
|---|---|
| WM | Niri |
| Theme | Stylix + Gruvbox |
| Terminal | Foot |
| Shell (bar · launcher · notifications · wallpaper · lock) | Noctalia |
| Editors | Nixvim · VS Code · Zed · Obsidian |
| File manager | Yazi |
| Browser | Zen |
| Containers | Docker + compose |

## Structure

Built by the repo-root flake (`.#desktop`, `homeConfigurations.idan`), on the
`nixpkgs-unstable` input.

| Path | What |
|---|---|
| `configuration.nix` | system config, performance tuning, nix caches |
| `hardware-configuration.nix`, `disko.nix` | hardware and the disk layout (`targetDisk`, below) |
| `home.nix` | home-manager: the shell aliases (`aliases` lists them), `sopsedit`/`sopsgen`, starship |
| `ssh-identities.nix` | name → host/user/port; drives the sops declarations and the ssh Host blocks |
| `secrets.sops.yaml` (+ `.example`) | `ssh/<name>` per identity, `workvpn/*` |
| `modules/nixos/` | containers, handy, netwatch, nvidia, ssh-identities, sshd, tailscale, work-vpn |
| `modules/home/` | one file per program (niri, nixvim, noctalia, zed, …) |
| `pkgs/` | excalirender, mmd2excalidraw, openconnect-saml |
| `claude/` | Claude Code skills installed by home-manager |
| `test.sh`, `test-wsl.sh` | validation without deploying |
| `FUTURE.md` | tooling under evaluation |

## SSH identities

`ssh-identities.nix` is the one list. It generates the `sops.secrets."ssh/<name>"`
declarations and the `programs.ssh` **`settings`** Host blocks (`matchBlocks`
is a deprecated alias in the pinned home-manager; `extraOptions` entries are
raw `ssh_config` directives). Each block gets `IdentityFile
/run/secrets/ssh/<name>` and `IdentitiesOnly yes`, and its Host pattern
matches both the alias and the real hostname. Public halves live in the
repo-root `ssh-pubkeys.nix`; `gatech` and `forgejo` are client keys for
third-party forges and have no entry there. Adding one is
[docs/deploy.md](../docs/deploy.md#add-an-ssh-identity).

The first `home-manager switch` refuses to clobber a hand-written
`~/.ssh/config`; move it aside once.

## Install media

**Ventoy USB** (<https://www.ventoy.net>) — one data partition holds all three
files:

| File | Source |
|---|---|
| `nixos-minimal-*.iso` | <https://nixos.org/download/#nixos-iso> |
| `BasicBastardSelfhosted.tar` | `git archive --format=tar -o "$USB/BasicBastardSelfhosted.tar" HEAD` (LF endings, no `.git`, no uncommitted changes) |
| `sops_age_key.txt` | the age private key |

If the live system cannot find the ISO mount, press `Ctrl-R` in Ventoy's menu
for GRUB2 mode. Remove the USB after the install so the key lives only on the
target disk.

**Tag the target disk from Windows** — with several identical drives, model
and size do not tell them apart. Disk Management (`Win+X`): on the target
disk, Shrink Volume by `1024` MB, then New Simple Volume on the unallocated
space — **no drive letter**, exFAT, label `NIXOS-INSTALL`. Check with
`Get-Volume | Where-Object FileSystemLabel -eq 'NIXOS-INSTALL'`. In the live
ISO:

```bash
lsblk -o NAME,SIZE,MODEL,LABEL,SERIAL                # the disk carrying NIXOS-INSTALL
ls -la /dev/disk/by-id/ | grep -v part | grep <SERIAL>
```

**`targetDisk` is deliberately unset.** `disko.nix` ships
`targetDisk = "/dev/disk/by-id/CHANGE_ME_TO_YOUR_DRIVE_ID"`: the value is
machine-specific and destructive (the other drives hold Windows). It matters
only when disko runs — not for `nix flake check` or a rebuild. Set it in the
live ISO, right before partitioning.

## Placeholders

| File | Setting |
|---|---|
| `disko.nix` | `targetDisk` (install time only) |
| `configuration.nix` | `networking.hostName`, `time.timeZone` |
| `home.nix` | `programs.git.settings.user.name` / `.email` |
| `modules/home/niri.nix` | `outputs` (from `niri msg outputs`) |

## After the install

- **home-manager bootstraps itself once** — the system config does not
  install its CLI:
  `nix run home-manager/master -- switch --flake ~/local/projects/server/BasicBastardSelfhosted#idan`.
  The repo must live at that path; the aliases hardcode it.
- **Join the tailnet by hand** (no autoconnect unit here):
  `sudo tailscale up --login-server=https://headscale.idanreed.com --accept-routes`,
  then Authentik as `idan`, not `akadmin`.

## Day to day

```bash
./test.sh          # flake check, eval, dry-run builds, statix, nixfmt (WSL or NixOS)
./test-wsl.sh      # the same, from Git Bash on Windows
nrs                # sudo nixos-rebuild switch --flake .#desktop
hms                # home-manager switch --flake .#idan (also restarts noctalia-shell)
nfu                # update the desktop's inputs only
```

The linters come from the flake's locked nixpkgs, so the gate runs the same
everywhere. `aliases` prints shell aliases only; `sopsedit`, `sopseditnvim`
and `sopsgen` are zsh functions in `home.nix`.

## Network monitoring (netwatch)

`modules/nixos/netwatch.nix` measures every path from this desktop to the
fleet and flags what is off with a desktop notification.

| Unit | What it records |
|---|---|
| `netwatch-probe` (timer, 2 min) | tailscale path and ping to services-vm and the VPS; DNS loss and latency through MagicDNS, AdGuard and 1.1.1.1, with a 100 qps burst every 10 min for rate limiting; every `*.svc` host from the Caddyfile, timed as connect, TLS and server time; Authentik's health check |
| `netwatch-passive` | this desktop's real DNS lookups (client to MagicDNS, and MagicDNS to AdGuard) and new tailnet TCP handshakes, with every slow or lost lookup by name and every connection to the VPS |
| `netwatch-notify` (user) | a raised flag becomes a notification, once per flag per 30 min |

A `*.svc` request is one LAN hop to services-vm. The hosts the Caddyfile puts
behind `import protected` add one round trip to Authentik's outpost on the
VPS, about 120 ms. The probe flags any other host whose server time is a VPS
round trip or more (the app is slow, or it waits on the VPS), forward auth
that does not match the Caddyfile, a `*.svc` name resolving away from
services-vm, and services-vm traffic relayed through DERP.

```bash
netwatch report --since -6h                           # flags, paths, DNS, slowest hosts
journalctl -t netwatch-probe -t netwatch-passive -p warning   # flags only
journalctl -t netwatch-probe -o cat | jq 'select(.kind=="http")'
```

The probe's DNS names sit under `netwatch.svc.idanreed.com`. Add
`||netwatch.svc.idanreed.com^` to AdGuard's ignored domains (Settings >
General settings, query log and statistics) to keep them out of its stats.
Thresholds and the resolver list are the `settings` block at the top of the
module.

## Performance tuning

Marked `# === CachyOS Performance ===` in the config.

| Tuning | Where |
|---|---|
| ZRAM swap (zstd, swappiness 150) | `configuration.nix` |
| sysctl (dirty bytes, cache pressure) | `configuration.nix` |
| I/O schedulers (bfq / mq-deadline / none) | `configuration.nix` |
| ananicy-cpp | `configuration.nix` |
| systemd timeouts and limits | `configuration.nix` |
| NTP (Cloudflare/Google) | `configuration.nix` |
| NVIDIA modprobe (PAT, memory init), audio power management, VA-API | `modules/nixos/nvidia.nix` |

## Key bindings

| Niri | | Neovim | |
|---|---|---|---|
| `Mod+Return` | terminal | `Space` | leader |
| `Mod+D` | launcher | `<leader>ff` | find files |
| `Mod+B` | browser | `<leader>fg` | live grep |
| `Mod+E` | file manager | `<leader>e` | file tree |
| `Mod+Q` | close window | `gd` | go to definition |
| `Mod+H/J/K/L` | focus | `K` | hover |
| `Mod+Shift+H/J/K/L` | move | `<leader>gg` | LazyGit |
| `Mod+1-5` | workspace | | |
| `Mod+F` / `Mod+Shift+F` | maximise / fullscreen | | |
| `Mod+Shift+E` | quit | | |
