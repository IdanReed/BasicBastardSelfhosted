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
  # Forgejo on the services VM, whose sshd is published LOOPBACK-ONLY
  # (127.0.0.1:10551) — so the desktop hops through the VM's own sshd via
  # ProxyJump (Caddy can't proxy SSH). Clone remote: forgejo:idan/<repo>.git.
  #
  # 🚨 CRITICAL: `host` MUST stay the alias "forgejo", NOT 127.0.0.1. The
  # generated Host pattern is "<name> <host>" (modules/home/ssh-identities.nix),
  # so a literal 127.0.0.1 here would hijack EVERY plain `ssh 127.0.0.1` with
  # User git / Port 10551 / the jump. extraOptions merges last, so its
  # HostName=127.0.0.1 override wins over the alias-derived HostName.
  #
  # No ssh-pubkeys.nix entry: this is a Forgejo user SSH key, not a host
  # authorizedKey (precedent: the gatech identity).
  forgejo = {
    host = "forgejo";
    user = "git";
    port = 10551;
    extraOptions = {
      HostName = "127.0.0.1";
      ProxyJump = "arcane-vm";
    };
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
    # Hetzner Storage Box sub-account (provisioned 2026-09-03). `user` is the
    # sub-account (base dir presented as /home, restic repo at /home/restic —
    # verified writable); HostName is the main box. Password auth cannot be
    # disabled on Hetzner boxes, so the account password stays valid — it is a
    # strong random value in the offline recovery artifact; SMB/WebDAV off.
    host = "u662946.your-storagebox.de";
    user = "u662946-sub1";
    port = 23; # Hetzner Storage Box SSH lives on 23, not 22
  };
}
