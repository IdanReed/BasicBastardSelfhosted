# Desktop client SSH identities — plain data, the single source of truth.
# modules/nixos/ssh-identities.nix derives sops.secrets."ssh/<name>" from it and
# modules/home/ssh-identities.nix derives the programs.ssh Host blocks, so
# adding an identity = one entry here + one key in secrets.sops.yaml (+ its
# pubkey in ssh-pubkeys.nix, all three copies).
#
# Shape: <name> = { host, user, port ? null, aliases ? [], extraOptions ? {} },
# where aliases are extra names added to the Host pattern (they still connect
# to `host`), and
# extraOptions are raw ssh_config directives by their upstream names
# (e.g. { ProxyJump = "vps"; }) merged into the generated Host block.
{
  # Git
  github = {
    host = "github.com";
    user = "git";
  };
  gatech = {
    host = "github.gatech.edu";
    user = "git";
  };
  # Forgejo's sshd is published loopback-only on the services VM, so hop through
  # the VM's own sshd. Clone remote: forgejo:idan/<repo>.git.
  #
  # 🚨 `host` MUST stay the alias "forgejo", NOT 127.0.0.1: the generated Host
  # pattern is "<name> <host>", so a literal IP here would hijack EVERY plain
  # `ssh 127.0.0.1` with User git / Port 10551 / the jump. extraOptions merges
  # last, so its HostName wins over the alias-derived one.
  #
  # No ssh-pubkeys.nix entry: this is a Forgejo user key, not a host
  # authorizedKey (precedent: gatech).
  forgejo = {
    host = "forgejo";
    user = "git";
    port = 10551;
    extraOptions = {
      HostName = "127.0.0.1";
      ProxyJump = "arcane-vm";
    };
  };

  # Server
  proxmox = {
    host = "10.0.0.2";
    user = "root";
  };
  # The services VM (the identity name predates the rename). Its tailnet
  # names are aliases so `ssh services-vm` picks up the key; they still
  # connect over the LAN address.
  arcane-vm = {
    host = "10.0.0.3";
    user = "idan";
    aliases = [
      "services-vm"
      "services-vm.tailnet.idanreed.com"
      "100.64.0.2"
    ];
  };
  vps = {
    host = "headscale-vps.tailnet.idanreed.com";
    user = "idan";
  };
  storagebox = {
    # Hetzner Storage Box sub-account: `user` is the sub-account (base dir
    # presented as /home, restic repo at /home/restic); HostName is the main
    # box. Password auth cannot be disabled on Hetzner boxes, so the account
    # password stays valid — it lives in the offline recovery artifact.
    host = "u662946.your-storagebox.de";
    user = "u662946-sub1";
    port = 23; # Hetzner Storage Box SSH lives on 23, not 22
  };
}
