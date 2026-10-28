# scanner/ — external-security-test box

A throwaway NixOS box that reproduces an **attacker outside the tailnet** and
runs the recon/enumeration phases of a private test brief against
infrastructure the operator owns. It holds no trust, joins no tailnet (phases 1-4), and is
destroyed after the run.

This is **not** the desktop (`nixos-de/`). It is a deliberately minimal config,
provisioned onto a fresh Vultr Ubuntu instance via `nixos-infect` — not a flake
host, because the box is ephemeral and provider-generated (hardware + network
config are produced on the box by infect).

## Files

| File | Role | Public-safe? |
|------|------|--------------|
| `scanner.nix` | Minimal NixOS module — toolkit + `claude-code` + the `idan` user + SSH hardening. Imported by infect via `NIXOS_IMPORT`. | yes (tools + one throwaway pubkey) |
| `infect.sh` | Operator-side: Ubuntu → NixOS, carrying `scanner.nix`. **Destructive**, reboots. | yes |
| `provision.sh` | Operator-side: clone the public repo on the box, deliver the private targets, verify the toolkit. | yes |
| `targets.env.example` | Shape of the targets file (placeholders only). | yes |

The **real** targets, the test brief and the Vultr API key live age-encrypted
in a private repo and never land here (this repo is mirrored to public
GitHub). `provision.sh` takes their paths from `SCANNER_TARGETS_SOPS` (required
unless `SKIP_TARGETS=1`) and `SCANNER_BRIEF` (optional).

## Bring-up

```bash
cd scanner
./infect.sh 149.28.124.97      # Ubuntu -> NixOS (reimages + reboots; ~5-10 min)
SCANNER_TARGETS_SOPS=<path> SCANNER_BRIEF=<path> \
  ./provision.sh 149.28.124.97 # clone repo + push targets + brief + verify tools
```

Then, manual (by construction — no credentials baked into the image):

1. **Auth Claude on the box:** `ssh -i ~/.ssh/vultr_scanner idan@<ip>`, run
   `claude`, log in (or export `ANTHROPIC_API_KEY`).
2. **Re-verify dynamic targets** before a run (home WAN v4 / v6 prefix are
   ISP-assigned): `curl -4 https://1.1.1.1/cdn-cgi/trace` from the home LAN,
   then update the encrypted targets file with `sopsedit`.
3. **Run the phases** from the brief (`~/scan/brief.md`), sourcing targets:
   `set -a; . ~/targets.env; set +a`. Keep nmap at `-T3` or gentler; scan only
   IPs you own.
4. **Tailnet is phase 5 only.** `tailscale` is installed but the daemon is off;
   join explicitly with `sudo tailscale up` as a dedicated test user when phase
   5 starts, and leave it off for phases 1-4.

## Teardown

Destroy the Vultr instance when done (hourly billing — a run costs cents). The
host key and `~/.ssh/vultr_scanner*` can then be removed locally, and the
scanner IP recorded in the brief goes stale.

## Toolchain

`nmap testssl nuclei subfinder dnsx gitleaks ssh-audit dnsutils(dig) whois
openssl curl wget jq git tailscale` + `claude-code`, `tmux ripgrep fd htop`.
All from nixpkgs `nixos-25.11` (matches the other two server flakes). `nuclei`
fetches its templates on first run (needs outbound network, which the box has).
