# Headscale VPS

The Hetzner Cloud VPS: Headscale (the tailnet's control plane) and Authentik
(the identity provider). The only publicly reachable host in the fleet.

Installing it, minting the first preauthkey and the first Authentik login are
[docs/bring-up.md](../docs/bring-up.md) §7, §8 and §14. Day-2 changes are
`nrs-vps` ([docs/deploy.md](../docs/deploy.md)). This file is the host's shape
and its break-glass paths.

## Shape

```
headscale-vps (.#headscale-vps)
├── caddy.service       native — the ONLY public listener, :80/:443, HTTP-01
│   ├── headscale.idanreed.com → 127.0.0.1:8080
│   └── auth.idanreed.com      → 127.0.0.1:9000
├── headscale.service   native — coordination + embedded DERP, loopback
├── authentik.service   systemd → docker compose: server, worker, PostgreSQL
├── alloy.service       native — ships the journal to the services VM
├── fail2ban            sshd and authentik jails
└── tailscale           joins its own tailnet via --login-server
```

Public ports: **22, 80, 443 TCP** and **3478 UDP** (STUN). Headscale and
Authentik bind loopback only. There is no deploy agent, sync timer or checkout
on the host: everything arrives by `nixos-rebuild switch --target-host`.

| Choice | Reason |
|---|---|
| Headscale is a native service | the tailnet never depends on the container runtime, and repairing it never needs the tailnet |
| Authentik is containerised, compose shipped in the flake | upstream-supported images and migrations; the unit runs `docker compose -f <store path> -p authentik up -d --wait`, the project name pinned because the store path changes every rebuild |
| Caddy in front of both | one process owns `:443`, and the OIDC issuer must be HTTPS on the standard port |
| HTTP-01, not DNS-01 | the host is public on :80, so no DNS plugin and no custom build |
| The Authentik admin surface is fenced | `/if/admin*` and `/api/v3/*` are 403 unless the request comes from the tailnet or loopback (`@restricted` in `modules/caddy.nix`), with narrow carve-outs for the flow executor and branding |
| No Tailscale SaaS | `derp.urls = [ ]` keeps the nixpkgs default from fetching Tailscale's DERP map; the embedded DERP (region 999) is the only relay |

## Files

| Path | What |
|---|---|
| `host.nix` | the module set the flake and the test harness share |
| `configuration.nix` | identity, firewall, fail2ban, nix settings |
| `disk-config.nix` | disko layout for the Hetzner disk |
| `deploy.sh` | the nixos-anywhere installer — **destructive** |
| `policy.hujson` | the headscale ACL |
| `modules/headscale.nix` | `services.headscale`, OIDC, embedded DERP |
| `modules/authentik.nix` | the compose unit and the `authentik.env` sops template |
| `modules/caddy.nix` | the vhosts and the `@restricted` matcher |
| `modules/log-shipper.nix` | Alloy → `vlogs-ingest.svc.idanreed.com` |
| `authentik/compose.yaml` | Authentik, applied on every rebuild |
| `authentik/blueprints/custom/` | every provider, application, group and declared user; applied by the worker |

## Access and secrets

- `authorizedKeys` is generated from the repo-root `ssh-pubkeys.nix` (`vps`,
  `backup-vps`). Never hand-edit it.
- The host's secrets are `secrets.sops.yaml` (YAML on purpose: sops-nix
  extracts per key only from yaml/json); the OIDC client secrets, idan's
  password, the vlogs token and the LDAP secrets come from the repo-root
  `secrets/shared.sops.json` — the same values the services VM renders.
  sops-nix decrypts them into `/run/secrets` at activation; no plaintext `.env`
  is written to disk.
- `modules/authentik.nix` renders Authentik's values into one template,
  `/run/secrets/rendered/authentik.env`, which the compose file reads;
  `restartUnits` restarts Authentik and headscale when a value they read
  changes.
- Edit with `sopsedit headscale-vps/secrets.sops.yaml`. The real file holds
  real values — never regenerate it from `secrets.sops.yaml.example`.

## Break-glass

**Authentik down or OIDC broken.** `oidc.only_start_if_oidc_is_available` is
`false`, so headscale boots and existing nodes keep working. The CLI does not
touch OIDC:

```bash
sudo headscale users list          # the NUMERIC id
sudo headscale nodes list
sudo headscale preauthkeys create -u <numeric-user-id> -e 1h
```

Mint under the **existing** `idan`, never a new user named `idan`: a second
`idan` makes the ACL's `idan@` resolve to neither, and every node loses
access.

**Into Authentik itself:** `akadmin` with `AUTHENTIK_BOOTSTRAP_PASSWORD`, or
`AUTHENTIK_BOOTSTRAP_TOKEN` for the API. No blueprint retires either. Before
the VPS is on the tailnet, reach the admin UI with
`ssh -L 9000:127.0.0.1:9000 idan@<VPS_IP>`.

## Troubleshooting

- **SSH refused after an install** — wait for the reboot, then
  `ssh-keygen -R <IP>`: rescue, the installer and the installed system each
  present a different host key.
- **headscale fails** (`journalctl -u headscale -f`) — HTTP-01 needs :80
  reachable and `headscale.idanreed.com` resolving here; `dns.base_domain`
  must not contain the `server_url` host (`tailnet.idanreed.com` has no public
  records); check `/run/secrets/HEADSCALE_OIDC_CLIENT_SECRET`.
- **A node registers but reaches nothing** — it registered under a cached
  `akadmin` session, and a node keeps the user it registered under. `sudo
  headscale nodes delete -i <id> --force`, then log it in again as `idan`
  from a private window: `tailscale up
  --login-server=https://headscale.idanreed.com --force-reauth`.
- **Authentik fails** (`systemctl status authentik`) — the unit stays
  `activating` until PostgreSQL and both Authentik processes are healthy, then
  goes `active (exited)`. A failure is almost always a missing secret: check that
  `/run/secrets/rendered/authentik.env` carries every key the template
  declares, then `docker logs authentik_server` / `authentik_worker`.
- **A blueprint did not apply** — the worker log names it. A provider name or
  slug declared twice, a `.yml` extension, or a comment-only `attrs:` each
  rolls the whole blueprint back.
