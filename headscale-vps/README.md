# Headscale VPS - NixOS Configuration

NixOS configuration for the Hetzner Cloud VPS running Headscale + Authentik.

## Architecture

```
Hetzner VPS (headscale-vps)
├── NixOS 25.11
├── caddy.service            (native systemd — the ONLY public listener, :80/:443)
│   ├── headscale.idanreed.com → 127.0.0.1:8080
│   └── auth.idanreed.com      → 127.0.0.1:9000
├── headscale.service        (native systemd — VPN coordination + DERP, loopback)
├── authentik.service        (systemd → docker compose — OIDC provider, loopback)
│   ├── server
│   ├── worker
│   ├── PostgreSQL
│   └── Redis
├── Fail2ban (SSH protection)
└── Tailscale (joins own network via --login-server)
```

Public ports: **22, 80, 443 TCP** and **3478 UDP** (STUN). Nothing else. Headscale
and Authentik both bind loopback only.

There is **no GitOps agent on this host** — no Arcane, no sync timer, no
mutable checkout. Everything is deployed by `nixos-rebuild switch` over SSH.

Headscale runs as a native systemd service rather than a container so that the
tailnet does not depend on the container runtime, and so it can never depend on
being reachable *over* the tailnet in order to be repaired. Authentik stays
containerised (upstream-supported images, monthly releases, DB migrations) but
its compose file ships in the flake and is applied by a systemd unit, so there
is no drift window and no polling.

Caddy exists because only one process can own `:443`, and Headscale's OIDC
issuer (`auth.idanreed.com`) needs to be reachable over HTTPS on the standard
port. It uses HTTP-01, so no DNS-provider plugin or custom build is needed —
unlike the services VM, which is tailnet-only and must use DNS-01.

## Prerequisites

1. **Hetzner Cloud account** with SSH key configured
2. **Nix installed** locally with flakes enabled
3. **AGE key** at `../sops_age_key.txt` (shared with services-vm)
4. **Public DNS records** — both must resolve to the VPS before first deploy,
   or ACME issuance fails and nothing is reachable over HTTPS:

   ```
   headscale.idanreed.com  A  <vps-public-ip>
   auth.idanreed.com       A  <vps-public-ip>
   ```

   Note `tailnet.idanreed.com` is the MagicDNS base domain and must NOT have
   public records — Headscale refuses to start if `server_url`'s hostname
   equals or is a subdomain of `dns.base_domain`.

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

# Check Caddy got certificates for BOTH names
sudo systemctl status caddy
curl -sI https://headscale.idanreed.com/health
curl -sI https://auth.idanreed.com/-/health/live/
```

### 6. First login and enrolling this host

Order matters: the VPS joins its own tailnet, so Headscale must exist first.

```bash
# On the VPS — create the user the ACL policy references, then a preauth key
sudo headscale users create idan
sudo headscale preauthkeys create --user idan --reusable --expiration 24h
```

Put that key in `.sops.env` as `TAILSCALE_AUTH_KEY`, re-encrypt, and rebuild;
`tailscale-autoconnect` will register against Headscale (it passes
`--login-server`, so a Headscale key is the correct kind — a Tailscale SaaS key
will not work).

Log into Authentik at `https://auth.idanreed.com` as `akadmin` with
`AUTHENTIK_BOOTSTRAP_PASSWORD`. 2FA enrolment is mandatory on first login —
have an authenticator app ready, and store the TOTP secret **off this
infrastructure** (see the circular-dependency note in
`ServerNotes/designs/core-oidc.md`).

### Break-glass: Authentik is down or OIDC is broken

`oidc.only_start_if_oidc_is_available` is `false`, so Headscale boots and
existing nodes keep working even with Authentik completely dead. The CLI is a
full administrative path that does not touch OIDC at all:

```bash
sudo headscale users list
sudo headscale preauthkeys create --user idan --expiration 1h
sudo headscale nodes list
```

This is the recovery path if Authentik's database is unrecoverable — enrol
nodes by preauth key while rebuilding identity.

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
