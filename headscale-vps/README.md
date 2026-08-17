# Headscale VPS - NixOS Configuration

NixOS configuration for the Hetzner Cloud VPS running Headscale + Authentik.

## Architecture

```
Hetzner VPS (headscale-vps)
├── NixOS 25.11
├── headscale.service        (native systemd — VPN coordination + DERP)
├── authentik.service        (systemd → docker compose — OIDC provider)
│   ├── server
│   ├── worker
│   ├── PostgreSQL
│   └── Redis
├── Fail2ban (SSH protection)
└── Tailscale (joins own network)
```

There is **no GitOps agent on this host** — no Arcane, no sync timer, no
mutable checkout. Everything is deployed by `nixos-rebuild switch` over SSH.

Headscale runs as a native systemd service rather than a container so that the
tailnet does not depend on the container runtime, and so it can never depend on
being reachable *over* the tailnet in order to be repaired. Authentik stays
containerised (upstream-supported images, monthly releases, DB migrations) but
its compose file ships in the flake and is applied by a systemd unit, so there
is no drift window and no polling.

## Prerequisites

1. **Hetzner Cloud account** with SSH key configured
2. **Nix installed** locally with flakes enabled
3. **AGE key** at `../sops_age_key.txt` (shared with services-vm)

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

### 3. Create Secrets

Copy `.sops.env.example` to `.sops.env`, fill in real values, and encrypt:

```bash
export SOPS_AGE_KEY_FILE=../sops_age_key.txt
cp .sops.env.example .sops.env
sops -e -i .sops.env
```

The flake will not evaluate until `.sops.env` exists.

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
sudo ls -la /var/lib/sops-nix/sops_age_key.txt

# Check Headscale (native service)
sudo systemctl status headscale
sudo journalctl -u headscale -f

# Check Authentik (compose driven by systemd)
sudo systemctl status authentik
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

All VPS secrets live in a single file, decrypted by sops-nix at activation.
No plaintext `.env` is ever written to disk.

| Key | Used by |
|-----|---------|
| `TAILSCALE_AUTH_KEY` | `tailscale-autoconnect.service` |
| `PG_PASS` | Authentik PostgreSQL |
| `AUTHENTIK_SECRET_KEY` | Authentik server + worker |
| `HEADSCALE_OIDC_CLIENT_SECRET` | Headscale `oidc.client_secret_path` **and** the Authentik blueprint (must match) |

To edit secrets:

```bash
export SOPS_AGE_KEY_FILE=../sops_age_key.txt
sops .sops.env
sudo nixos-rebuild switch --target-host idan@<VPS_IP> --use-remote-sudo --flake .#headscale-vps
```

## Comparison with Services VM

| Aspect | Services VM (Proxmox) | VPS (Hetzner) |
|--------|----------------------|---------------|
| Provisioning | nixos-generators → VMA image | nixos-anywhere → kexec install |
| AGE key injection | cloud-init at boot | --extra-files during install |
| Deploy script | `nixos/build_proxmox.sh` | `headscale-vps/deploy.sh` |
| Rebuild command | `.#services-vm` | `.#headscale-vps` |

Both use the same AGE key (`../sops_age_key.txt`) and SOPS configuration.

## Files

```
headscale-vps/
├── flake.nix           # Flake definition
├── disk-config.nix     # Disko partitioning for Hetzner
├── configuration.nix   # Main NixOS config
├── modules/
│   ├── headscale.nix   # services.headscale (native systemd)
│   └── authentik.nix   # systemd unit driving docker compose
├── authentik/
│   ├── compose.yaml    # shipped in the flake, applied on rebuild
│   └── blueprints/custom/headscale-oidc.yml
├── deploy.sh           # Deployment script
├── .sops.env.example   # Secrets template
└── README.md           # This file
```

## Troubleshooting

### SSH connection refused after deploy

Wait 1-2 minutes for reboot. If still failing:
- Check Hetzner Console for boot errors
- Verify SSH key is in `configuration.nix`

### Headscale failing

```bash
sudo journalctl -u headscale -f
```

Common issues:
- ACME cannot complete HTTP-01 — port 80 must be reachable and
  `headscale.idanreed.com` must resolve to this VPS
- `dns.base_domain` must not equal the `server_url` hostname (headscale
  refuses to start otherwise)
- OIDC secret unreadable — check `/run/secrets/HEADSCALE_OIDC_CLIENT_SECRET`

### Authentik failing

```bash
sudo systemctl status authentik
sudo journalctl -u authentik -f
```

`authentik.service` runs `docker compose up -d --wait`, so it stays in
`activating` until PostgreSQL and Redis pass their healthchecks, then goes
`active (exited)`. A failure here usually means a missing secret — verify
`/run/secrets/rendered/authentik.env` exists and has all four keys.

### Authentik not starting

```bash
docker logs authentik_server
docker logs authentik_db
```

Check PostgreSQL is healthy before server starts.
