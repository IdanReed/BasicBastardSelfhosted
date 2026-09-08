# services-vm Samba shares over the tailnet.
#
# noauto + x-systemd.automount: a hard cifs entry would block boot whenever the
# VM or tailscaled is down. `seal` is MANDATORY — the server sets
# `smb encrypt = required` (stacks/samba/config.yml).
# `services-vm` resolves via headscale MagicDNS; swap for the tailnet IP if off.
{ config, pkgs, ... }:
let
  common = [
    "credentials=${config.sops.templates."smb-idan.cred".path}"
    "seal"
    "vers=3.1.1"
    "uid=1000"
    "gid=100"
    "file_mode=0644"
    "dir_mode=0755"
    "iocharset=utf8"
    "noauto"
    "x-systemd.automount"
    "x-systemd.idle-timeout=600"
    "x-systemd.mount-timeout=15"
    "_netdev"
  ];
in
{
  environment.systemPackages = [ pkgs.cifs-utils ];

  # Root-only; only the credentials template below dereferences it. Keeping the
  # password in a file rather than mount options keeps it off the process args.
  sops.secrets."SAMBA_IDAN_PASSWORD" = { };

  sops.templates."smb-idan.cred".content = ''
    username=idan
    password=${config.sops.placeholder."SAMBA_IDAN_PASSWORD"}
  '';

  fileSystems."/mnt/samba/shared" = {
    device = "//services-vm/shared";
    fsType = "cifs";
    options = common;
  };

  # Server-side `valid users = idan` + 0700 dir keep others out.
  fileSystems."/mnt/samba/idan" = {
    device = "//services-vm/idan";
    fsType = "cifs";
    options = common;
  };
}
