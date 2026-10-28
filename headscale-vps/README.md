# Headscale VPS

NixOS configuration for the Hetzner Cloud VPS: Headscale (tailnet control plane)
and Authentik (identity provider). This is the only publicly reachable host in
the fleet.

**Bring-up is not documented here.** Creating the box, rescue mode,
`./deploy.sh`, minting the first preauth key, and the Authentik first login are
`ServerNotes/designs/deploy-handbook.md` §7, §8 and §14, in order. Day-2 changes
are `nrs-vps` (see `docs/deploy.md`). What follows is the architecture and the
things that are specific to this host.

## Architecture

```
Hetzner VPS (headscale-vps)
├── NixOS 26.05
├── caddy.service       native systemd — the ONLY public listener, :80/:443
│   ├── headscale.idanreed.com → 127.0.0.1:8080
│   └── auth.idanreed.com      → 127.0.0.1:9000
├── headscale.service   native systemd — tailnet coordination + embedded DERP, loopback
├── authentik.service   systemd → docker compose — server, worker, PostgreSQL
├── alloy.service       native systemd — ships the journal to the services VM
├── fail2ban            sshd and authentik jails
└── tailscale           joins its own tailnet via --login-server
```

Public ports: **22, 80, 443 TCP** and **3478 UDP** (DERP STUN). Nothing else.
Headscale and Authentik both bind loopback only.

**There is no GitOps agent on this host** — no Komodo, no sync timer, no mutable
checkout. Everything is deployed by `nixos-rebuild switch --target-host` over
SSH, which is the whole reason the VPS and the services VM behave differently.

### Why the pieces are shaped this way

- **Headscale is a native systemd service, not a container**, so the tailnet
  never depends on the container runtime, and so repairing it can never require
  being reachable *over* the tailnet.
- **Authentik stays containerised** (upstream-supported images, monthly releases,
  DB migrations), but its compose file ships *inside the flake* and is applied by
  a systemd unit running `docker compose -f <store-path> -p authentik up -d
  --wait`. The project name is pinned because the store path changes on every
  rebuild. No drift window, no polling.
- **Caddy exists because only one process can own `:443`**, and Headscale's OIDC
  issuer (`auth.idanreed.com`) must be reachable over HTTPS on the standard port.
- **HTTP-01, not DNS-01.** This host is publicly reachable on :80, so no
  DNS-provider plugin and no custom Caddy build — unlike the services VM, which
  is tailnet-only and must use DNS-01 against Cloudflare.
- **The Authentik admin surface is fenced.** `/if/admin*` and `/api/v3/*` are
  403'd unless the request comes from the tailnet or loopback (the `@restricted`
  matcher in `modules/caddy.nix`), with narrow carve-outs for the flow executor
  and root branding config. Reaching it before the VPS is on the tailnet:
  `ssh -L 9000:127.0.0.1:9000 idan@<VPS_IP>`.
- **Tailscale-the-SaaS is not a dependency.** `modules/headscale.nix` sets
  `derp.urls = [ ]` explicitly so the nixpkgs default never fetches Tailscale's
  public DERP map; the embedded DERP server (region 999) is the only relay.

### Access and secrets

- `authorizedKeys` is **generated from the repo-root `ssh-pubkeys.nix`** (the
  `vps` and `backup-vps` entries), which both servers import; the desktop's copy
  is held byte-identical by the `ssh-pubkey-parity` lint. Never hand-edit it in
  `configuration.nix`.
- The VPS's own secrets live in `secrets.sops.yaml`; the app OIDC client
  secrets, the login passwords and the vlogs token are read from the
  repo-root `secrets/shared.sops.json` (`secrets/shared.nix`), the same values
  the services VM renders. Both are decrypted per key by sops-nix at activation
  into `/run/secrets` (the inventory is `deploy-handbook.md` §4). **No plaintext `.env` is ever written to disk.** YAML rather
  than dotenv is load-bearing: `sops-install-secrets` applies the per-secret key
  only for yaml/json.
- The age private key lives only at `/var/lib/sops-nix/sops_age_key.txt`, never
  in the workspace. Edit secrets with `sopsedit headscale-vps/secrets.sops.yaml`
  (or `sopseditnvim`), which sudo-reads the key for one invocation. The real file
  holds real values — **do not regenerate it from `secrets.sops.yaml.example`**;
  sops has no append-without-decrypt.
- `modules/authentik.nix` renders all of them into one
  `sops.templates."authentik.env"` at `/run/secrets/rendered/authentik.env`,
  which is what the compose file reads.

## Files

```
headscale-vps/                  (built by the repo-root flake: .#headscale-vps)
├── host.nix                    the module set the flake and the test harness share
├── configuration.nix           identity, firewall, fail2ban, nix settings
├── disk-config.nix             disko partitioning for the Hetzner disk
├── deploy.sh                   nixos-anywhere installer (DESTRUCTIVE)
├── policy.hujson               headscale ACL
├── secrets.sops.yaml{,.example}
├── modules/
│   ├── headscale.nix           services.headscale, embedded DERP
│   ├── authentik.nix           systemd unit driving docker compose + the env template
│   ├── caddy.nix               HTTP-01 vhosts, the @restricted matcher
│   └── log-shipper.nix         Alloy → vlogs-ingest.svc.idanreed.com
└── authentik/
    ├── compose.yaml            shipped in the flake, applied on rebuild
    └── blueprints/custom/      21 blueprints: 18 <app>-oidc.yaml, plus
                                forward-auth, login-hardening, email-verified
```

## Break-glass: Authentik is down, or OIDC is broken

`oidc.only_start_if_oidc_is_available` is `false`, so Headscale boots and
existing nodes keep working with Authentik completely dead. The CLI is a full
administrative path that does not touch OIDC:

```bash
sudo headscale users list          # note the NUMERIC id you want
sudo headscale nodes list
sudo headscale preauthkeys create -u <numeric-user-id> -e 1h
```

`-u` takes the numeric user id, not the name. **Mint under the existing `idan`
user, never a new one called `idan`** — a second user with that name makes the
`idan@` in `policy.hujson` ambiguous and it then resolves to neither, which
takes tailnet access away from every node.

`akadmin` plus `AUTHENTIK_BOOTSTRAP_TOKEN` are the other break-glass path into
Authentik itself. No blueprint retires either; both are permanent, full-API,
never-rotated fleet-root credentials.

## Troubleshooting

**SSH refused after an install.** Wait 1–2 minutes for the reboot, then
`ssh-keygen -R <IP>` — rescue mode, the installer and the installed system each
present a different host key.

**Headscale failing** (`sudo journalctl -u headscale -f`):

- ACME cannot complete HTTP-01 — port 80 must be reachable and
  `headscale.idanreed.com` must resolve to this VPS.
- `dns.base_domain` must not equal or contain the `server_url` hostname;
  headscale refuses to start otherwise. `tailnet.idanreed.com` must have no
  public records.
- OIDC secret unreadable — check `/run/secrets/HEADSCALE_OIDC_CLIENT_SECRET`.

**A node registers but can reach nothing.** It was registered under the wrong
Authentik identity (a cached `akadmin` session), so the ACL's `idan@` does not
cover it. A node belongs to the user it registered under for good — headscale
cannot move it — so delete it and register it again as `idan`:
`sudo headscale nodes delete -i <id>`, then on the node
`tailscale up --login-server=https://headscale.idanreed.com --force-reauth`
(log in as idan) or `--authkey` with a key minted for idan's numeric user id.

**Authentik failing** (`sudo systemctl status authentik`). The unit runs
`docker compose up -d --wait`, so it stays `activating` until PostgreSQL and
both Authentik processes pass their healthchecks, then goes `active (exited)`.
A failure here is almost always a missing secret: verify
`/run/secrets/rendered/authentik.env` exists and carries every key
`modules/authentik.nix` declares. Then
`docker logs authentik_server` / `docker logs authentik_db`.
