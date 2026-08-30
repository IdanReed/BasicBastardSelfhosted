# Desktop client SSH identities — plain data, the single source of truth.
# modules/nixos/ssh-identities.nix derives sops.secrets."ssh/<name>" from it
# and modules/home/ssh-identities.nix derives programs.ssh.matchBlocks from
# it, so adding identity = one entry here + one key in secrets.sops.yaml
# (+ its pubkey in ssh-pubkeys.nix, all three copies).
#
# Shape: <name> = { host, user, port ? null, extraOptions ? {} }, where
# extraOptions are raw ssh_config directives by their upstream names
# (e.g. { ProxyJump = "vps"; }) merged into the generated Host block.
{
  # ---
  # Git
  # ---
  github = {
    host = "github.com";
    user = "git";
  };
  gatech = {
    host = "github.gatech.edu";
    user = "git";
  };
  # ---
  # Server
  # ---
  proxmox = {
    host = "10.0.0.2";
    user = "root";
  };
  arcane-vm = {
    host = "10.0.0.3";
    user = "idan";
  };
  vps = {
    host = "headscale-vps.tailnet.idanreed.com";
    user = "idan";
  };
  storagebox = {
    # WHY placeholder: the Hetzner Storage Box is not provisioned yet, so no
    # real box name exists. Idan fills in the real u<number> host/user when
    # ordering it; u000000 is Hetzner's documented example, guaranteed unreal.
    host = "u000000.your-storagebox.de";
    user = "u000000";
    port = 23; # Hetzner Storage Box SSH lives on 23, not 22
  };
}
