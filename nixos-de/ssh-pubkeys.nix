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
  github = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMYQK8ygfSY1qmBj7jxBT6VNH7uVm8Lb1mF1ec9Pz/z5 idan@idanreed.com";
  proxmox = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBb2tDbaA5I2xnvbJW13a0jLF+c/Sk7z/HfUFCilLHHw proxmox@idanreed";
  arcane-vm = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKlZMaVxyWGjztwZErMeNN5bqOqfCYoGS1XdfqTQmH/T arcane-vm@idanreed";
  vps = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMYlaE0EC4T/rrgW1hS78pzXuy0ZbniyxXL0WmoxWcA2 vps@idanreed";
  storagebox = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH59fvm9TJ4iLYgSq5N0Jsb6z6/9Rlpn7o6L/8/F77IB storagebox@idanreed";
  # Host identities - private halves live in the owning host's
  # secrets.sops.yaml.
  backup-vps = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAFLwk+iktnaV0kzfKk6zfiyFzh590t8haOBihzxhV91 backup-vps@idanreed"; # services VM -> VPS state pull
  backup-storagebox = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPZ1md5BL1k7ZmiV1anmrZZQFjqXXemyVUiP66tsTM+7 backup-storagebox@idanreed"; # backrest -> Hetzner Storage Box
}
