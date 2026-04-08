# Headscale VPS - NixOS Configuration

NixOS configuration for the Hetzner Cloud VPS running Headscale + Authentik.

## Architecture

```
Hetzner VPS (headscale-vps)
├── NixOS 24.11
├── Docker
│   ├── Authentik (OIDC provider)
│   │   ├── server
│   │   ├── worker
│   │   ├── PostgreSQL
│   │   └── Redis
│   └── Headscale (VPN coordination)
├── stack-sync.service (GitOps deployment)
├── Fail2ban (SSH protection)
└── Tailscale (joins own network)
```

## Prerequisites

1. **Hetzner Cloud account** with SSH key configured
2. **Nix installed** locally with flakes enabled
3. **AGE key** at `../age-key.txt` (shared with services-vm)

## Deployment

### 1. Create Hetzner VPS

```bash
# Via Hetzner Cloud Console or CLI:
# - Location: fsn1/nbg1/hel1
# - Image: Ubuntu 22.04
# - Type: CPX11 (2 vCPU, 2GB RAM) minimum, CPX21 recommended for Authentik
# - SSH Key: Select your key
# - Note the IP address
```

### 2. Add SSH Key to Configuration

Edit `configuration.nix`:

```nix
users.users.idan.openssh.authorizedKeys.keys = [
  "ssh-ed25519 AAAA... idan@desktop"  # Your actual key
];
```

### 3. Update Git Repo URL

Edit `modules/stack-sync.nix`:

```nix
REPO_URL="https://github.com/yourusername/BasicBastardSelfhosted.git"
```

### 4. Deploy

```bash
./deploy.sh <VPS_IP>
```

This will:
- Verify AGE key and SSH connectivity
- Run nixos-anywhere to install NixOS
- Inject AGE key via `--extra-files`
- Reboot into NixOS

### 5. Verify

```bash
ssh idan@<VPS_IP>

# Check AGE key
sudo ls -la /var/lib/sops-nix/key.txt

# Check stack-sync
sudo systemctl status stack-sync
sudo journalctl -u stack-sync -f

# Check containers (after first sync)
docker ps
```

## Updating Configuration

For config changes that don't require a full reinstall:

```bash
nixos-rebuild switch \
  --target-host idan@<VPS_IP> \
  --use-remote-sudo \
  --flake .#headscale-vps
```

## Secrets Management

Secrets are encrypted with SOPS + AGE:

| File | Contents |
|------|----------|
| `.sops.env` | VPS host secrets (Tailscale auth key) |
| `../stacks/authentik/.sops.env` | Authentik secrets |
| `../stacks/headscale/.sops.env` | Headscale OIDC secrets |

To edit secrets:

```bash
export SOPS_AGE_KEY_FILE=../age-key.txt
sops stacks/authentik/.sops.env
```

## Comparison with Services VM

| Aspect | Services VM (Proxmox) | VPS (Hetzner) |
|--------|----------------------|---------------|
| Provisioning | nixos-generators → VMA image | nixos-anywhere → kexec install |
| AGE key injection | cloud-init at boot | --extra-files during install |
| Deploy script | `nixos/build_proxmox.sh` | `headscale-vps/deploy.sh` |
| Rebuild command | `.#services-vm` | `.#headscale-vps` |

Both use the same AGE key (`../age-key.txt`) and SOPS configuration.

## Files

```
headscale-vps/
├── flake.nix           # Flake definition
├── disk-config.nix     # Disko partitioning for Hetzner
├── configuration.nix   # Main NixOS config
├── modules/
│   └── stack-sync.nix  # GitOps: git pull → decrypt → docker compose
├── deploy.sh           # Deployment script
├── .sops.env.example   # Secrets template
└── README.md           # This file
```

## Troubleshooting

### SSH connection refused after deploy

Wait 1-2 minutes for reboot. If still failing:
- Check Hetzner Console for boot errors
- Verify SSH key is in `configuration.nix`

### stack-sync failing

```bash
sudo journalctl -u stack-sync -f
```

Common issues:
- Git repo URL incorrect
- AGE key missing or wrong permissions
- Docker not ready (wait and retry)

### Authentik not starting

```bash
docker logs authentik_server
docker logs authentik_db
```

Check PostgreSQL is healthy before server starts.
