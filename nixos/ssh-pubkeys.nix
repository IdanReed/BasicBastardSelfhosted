# SSH public keys by identity name. CANONICAL COPY: nixos-de/ssh-pubkeys.nix;
# nixos/ and headscale-vps/ carry byte-identical copies because a flake
# cannot reference paths outside its own root. The ssh-pubkey-parity lint
# fails the harness if the three copies drift.
#
# null = keypair not generated yet. Consumers filter nulls, so an unfilled
# entry means "no access granted" rather than an eval failure; the lint
# WARNs (without failing) while any entry is null.
#
# Adding an identity: add the entry here (all three copies), put the private
# half in the owning secrets.sops.yaml (see CLAUDE.md "SSH identities").
{
  # Desktop (nixos-de) client identities - private halves live in
  # nixos-de/secrets.sops.yaml under ssh/<name>.
  github = null;
  proxmox = null;
  arcane-vm = null;
  vps = null;
  storagebox = null;
  # Host identities - private halves live in the owning host's
  # secrets.sops.yaml.
  backup-vps = null; # services VM -> VPS state pull
  backup-storagebox = null; # backrest -> Hetzner Storage Box
}
