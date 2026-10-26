# BasicBastardSelfhosted

A declaratively-managed personal homelab: **NixOS** flakes for the hosts,
**Docker Compose** stacks for the services, **Komodo** GitOps for deploys,
**Authentik** for single sign-on, all fronted by **Caddy** and reachable only
over a **Tailscale / Headscale** tailnet.

---

## Disclaimer — read this first

**This is a personal project, not a product.** It is one operator's homelab,
shared for reference and curiosity. There is no support, no stability guarantee,
and no promise it will keep working tomorrow. It is *not* a template: almost
everything is pinned to this specific fleet — real hostnames and domains, a
Proxmox VM at a fixed address, a Hetzner VPS, and particular hardware (an Intel
Arc A380 for transcode, an RTX-class desktop GPU, a Hetzner Storage Box). Lift
any of it out of context and expect to rework it.

**It was built with heavy LLM assistance (Claude Code).** The NixOS config, the
compose files, the init scripts, *and* the design docs / research annexes in the
sibling `ServerNotes` repo were largely LLM-generated and LLM-reviewed. Treat all
of it accordingly: **verify before you reuse anything.** There may be subtle
errors an LLM introduced and a human skimmed past. This repo is a record of what
was built and why — not authoritative guidance on how you should build yours.

**Secrets are SOPS-encrypted (age).** Nothing sensitive is committed in
cleartext — application secrets live in encrypted `secrets.sops.json` files, OS
secrets in `secrets.sops.yaml`, and the private key never enters the repo. That said,
the security model was designed for *this* threat model (tailnet-only exposure,
one operator). Don't assume it fits yours.

---

## Architecture — the declarative goal

The intent is that the whole fleet comes up **from the repo, with no manual
clicking**: the OS is defined in NixOS config, the services in compose files,
the secrets in SOPS+age, and deploys happen via GitOps rather than by hand.

The moving parts (the repo-level layout and cross-repo conventions live in the
sibling-repo `CLAUDE.md` files; the essentials):

- **Three deploy targets**: the two servers are one flake at the repo root
  (`.#services-vm`, `.#headscale-vps`); the desktop has its own in `nixos-de/`.
  - **Services VM** (`nixos/`, Proxmox, `10.0.0.3`) — the Docker host. Deploy
    plane is **Komodo** GitOps: a push to Forgejo fires one webhook, Komodo
    re-applies `komodo/sync/` and deploys every stack whose files changed.
    sops-nix renders each stack's env on the host, so the age key never
    reaches the container that runs compose. Komodo and Forgejo themselves run
    from the flake.
  - **Headscale VPS** (`headscale-vps/`, Hetzner) — the only public host.
    Deployed by `nixos-rebuild --target-host` over SSH; no manager, no checkout
    on the host. Runs Headscale (native systemd) and Authentik (containerised).
  - **Desktop** (`nixos-de/`) — the personal workstation and admin box; local
    `nixos-rebuild` / `home-manager`.
- **Caddy** — reverse proxy for `*.svc.idanreed.com`, DNS-01 wildcard TLS,
  bound to the tailnet IP only. Nothing at home is exposed publicly.
- **Authentik** — the identity provider: native **OIDC** for apps that support
  it, plus Caddy **forward-auth** for apps that don't. One IdP for both hosts.
- **SOPS + age** — one key encrypts everything, and a value is stored once:
  `secrets.sops.yaml` per host for OS secrets, `secrets.sops.json` per stack,
  and `secrets/shared.sops.json` for what both hosts read (OIDC client secrets,
  login passwords). The private key lives only at
  `/var/lib/sops-nix/sops_age_key.txt` on each host.

**The honest caveat:** declarative-first is the *goal*, not a claim of 100%
coverage. A handful of services force an irreducible manual step — a browser-only
setup wizard, a DB-only OIDC toggle, a "first login becomes owner" trap. Those
are catalogued, with the exact step and *why* it can't be declarative, in
[`docs/for-shame.md`](docs/for-shame.md).

---

## Services

Each stack owns a 50-port block starting at 10000; the tiers below map to those
blocks. The authoritative inventory (ports, volumes, images, full notes) is
`ServerNotes/designs/_overview.md`.

**Auth legend:** **OIDC** = native OpenID Connect via Authentik · **FwdAuth** =
Caddy forward-auth to Authentik (the app has no SSO of its own) · **Plugin** =
SSO needs a runtime plugin · **Local** = the app's own accounts. Some apps stack
two (e.g. FwdAuth + a local login underneath).

Per-service *state* — what is deployed, what is blocked on a credential — lives
in `ServerNotes/designs/deploy-status.md`, not in this table.

### Infra (10000–10049)

| Service | Auth | What it is |
|---|---|---|
| Komodo | FwdAuth | GitOps deploy plane (Core on loopback :10000, Periphery mounts the socket) |
| Ntfy | — | Failure-notification hub, tailnet-only |
| Backrest | own | Restic backup orchestrator + web UI (to the Storage Box) |
| Proton Bridge (hydroxide) | Local | SMTP/IMAP/CardDAV bridge for Proton Mail; feeds Ntfy alerts |
| Caddy | — | Reverse proxy for `*.svc.idanreed.com`, DNS-01 wildcard cert |
| Tailscale | — | Tailnet client, pointed at self-hosted Headscale |

### Media (10050–10099)

| Service | Auth | What it is |
|---|---|---|
| Jellyfin | Plugin | Media server, Arc A380 hardware transcode |
| Radarr / Sonarr | FwdAuth | Movie / TV management |
| Prowlarr | FwdAuth | Indexer management |
| Bazarr | FwdAuth | Subtitle automation |
| Profilarr | FwdAuth | Syncs Dictionarry quality profiles to the *arrs |
| Seerr | Local | Request UI; authenticates against Jellyfin accounts (no OIDC on the stable tag) |
| Cleanuparr | FwdAuth | Download-queue cleanup (configured in its own web UI) |
| ClamAV | — | Scans all downloads; promotes clean audiobooks to the books drop |
| qBittorrent | Local | Torrent client in gluetun's netns; its own seeded WebUI credential |
| Gluetun | — | VPN tunnel + kill-switch for the download path (provider-agnostic) |
| SuggestArr | FwdAuth | Planned — Jellyfin suggestions |

### Data (10100–10149)

| Service | Auth | What it is |
|---|---|---|
| Paperless-ngx | OIDC | Document management + OCR |
| Immich | OIDC | Photo management |
| Samba | Local | SMB file server, tailnet-only (SSO not achievable — built `--without-ldap`) |

### Books (10150–10199)

| Service | Auth | What it is |
|---|---|---|
| Kavita | OIDC | Ebook library (EPUB/PDF), OPDS, KOReader sync |
| Shelfmark | FwdAuth | Ebook search + download |
| Audiobookshelf | OIDC | Audiobook library + player, progress sync |

### Notes / Sync (10200–10249)

| Service | Auth | What it is |
|---|---|---|
| rmfakecloud | Local | reMarkable cloud replacement |
| Syncthing | FwdAuth + local | Bidirectional file sync (server ↔ reMarkable) |
| SilverBullet | FwdAuth + local | File-on-disk markdown wiki (mirrored to Forgejo) |
| Outline | OIDC | Database-backed wiki (OIDC is the only login — no local accounts) |

*(SilverBullet, BookStack and Outline run together as a temporary wiki bake-off.)*

### Automation (10250–10299)

| Service | Auth | What it is |
|---|---|---|
| Home Assistant | Local | Home automation (OIDC deferred) |
| Mosquitto | Local | MQTT broker (Frigate → Home Assistant) |
| Frigate | FwdAuth | NVR + object detection (CPU detector until GPU passthrough lands) |
| Windmill | FwdAuth | Workflow orchestration (reMarkable OCR, Paperless AI, LLM tasks) |

*(A Windmill GPU worker + Ollama run on the desktop, not the services VM.)*

### Tracking (10300–10349)

| Service | Auth | What it is |
|---|---|---|
| BookStack | OIDC | Personal wiki (MariaDB) |
| Homebox | OIDC | Home inventory |
| Karakeep | OIDC | Bookmarks + optional AI |
| Firefly III | FwdAuth | Money tracking (+ Importer, SimpleFIN) |
| Firefly Importer | FwdAuth | SimpleFIN transaction import |
| Dawarich | OIDC | Location tracking (PostGIS) |
| Ghostfolio | OIDC | Portfolio tracker — *evaluation* |
| Owl | FwdAuth | Retirement planner — *evaluation* |
| Actual Budget | Local | Budgeting + SimpleFIN — *evaluation* (OIDC staged, DB-gated) |
| Wealthfolio | Local | Portfolio tracker — *evaluation* (OIDC staged, shipped off) |

### Food (10350–10399)

| Service | Auth | What it is |
|---|---|---|
| Tandoor | OIDC | Recipe management |
| Wger | FwdAuth | Calorie / workout tracking |
| Mealie | OIDC | Recipe management — *evaluation* (Tandoor rival) |

### Util (10400–10449)

| Service | Auth | What it is |
|---|---|---|
| Vaultwarden | OIDC + FwdAuth on `/admin` | Bitwarden-compatible password backend |
| BentoPDF | FwdAuth | Client-side PDF toolkit |
| Glance | FwdAuth | Feed + service-link dashboard |
| Mazanoke | FwdAuth | In-browser image optimizer (strips EXIF) |
| OnlyOffice DocSpace | Local | Document collaboration; its own portal accounts. Its only SSO is SAML 2.0, not yet exchanged with Authentik |
| IT-Tools | FwdAuth | 80+ developer utilities (sharevb fork) |
| Excalidraw (AstraDraw) | Local | Persistent whiteboard workspace (OIDC staged, shipped off) |

### Monitoring (10450–10499)

| Service | Auth | What it is |
|---|---|---|
| Gatus | FwdAuth | Availability monitoring (config-file only) |
| Beszel | FwdAuth | CPU/RAM/disk-trend/network metrics + alerts (hub + agent) |
| Grafana | FwdAuth | Log exploration over VictoriaLogs |
| VictoriaLogs | — | Log store (size-based retention; replaced Loki) |
| Alloy | — | Journal collector → VictoriaLogs |
| Speedtest Tracker | FwdAuth | Deferred — FwdAuth vs. scrape endpoint undecided |

### Game (10500–10549)

No panel deployed — evaluated and rejected (AMP dead, Pterodactyl socket-unsafe).
The recorded plan is one compose stack per game behind an idle-hibernation waker.

### Dev (10550–10599)

| Service | Auth | What it is |
|---|---|---|
| Forgejo | own | Git root (GitHub is a push mirror); SSH-first, also the GitOps source |
| DevPod | FwdAuth | Planned — cloud dev environments |

### VPS-hosted (Hetzner, not the services VM)

| Service | Auth | What it is |
|---|---|---|
| Headscale | OIDC | Tailnet coordination + embedded DERP (native systemd, `headscale.idanreed.com`) |
| Authentik | IdP | The identity provider itself (`auth.idanreed.com`) |
| Caddy (VPS) | — | The sole public listener; TLS for Headscale + Authentik |

---

## Docs

Operator runbooks live in this repo:

- [`docs/deploy.md`](docs/deploy.md) — the day-2 quick reference: commit →
  switch → push, how a stack deploys, the secrets commands, the two ordering
  traps, and the gotcha list.
- [`docs/for-shame.md`](docs/for-shame.md) — the catalogue of manual,
  non-declarative bring-up steps: for each, the exact step, *why* the app makes
  it impossible to automate, and whether it survives a container recreate.
- [`tests/README.md`](tests/README.md) — what the VM test harness covers, what it
  cannot, and the findings ledger from building it.

The **from-scratch bring-up procedure** (`designs/deploy-handbook.md`), the
**day-2 procedures** (`maintenance-handbook.md`), the authoritative service
inventory (`_overview.md`), and the design docs and research annexes live in the
sibling **`ServerNotes`** repo, not in this one.
