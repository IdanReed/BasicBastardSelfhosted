# Mounts the services-vm Samba shares over the tailnet.
#
# WHY on-demand automount (noauto + x-systemd.automount): a hard cifs entry
# would block boot whenever the VM is down or tailscaled has not come up yet.
# With automount the mount is attempted only on first access to the path and
# unmounts itself after idle, so a missing server is a slow `ls`, never a failed
# boot.
#
# Auth: idan's ONE password — the SAMBA_IDAN_PASSWORD twin that secrets-gen
# (manifest user/idan) also writes here. Rendered into a root-only credentials
# file via sops-nix so the password never lands in the mount options / process
# args. `seal` is MANDATORY: the server sets `smb encrypt = required`
# (stacks/samba/config.yml) and refuses an unencrypted session.
#
# Host: the server binds tailscale0 and allows 100.64.0.0/10, so `services-vm`
# resolves via headscale MagicDNS once tailscaled is up. If MagicDNS is off,
# swap the device host for the tailnet IP.
{ config, pkgs, ... }:
let
  common = [
    "credentials=${config.sops.templates."smb-idan.cred".path}"
    "seal" # server: smb encrypt = required
    "vers=3.1.1"
    "uid=1000" # idan on the desktop (isNormalUser → first uid)
    "gid=100" # users
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

  # Root-only; only the credentials template below dereferences it.
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

  # idan's private tree; the server's `valid users = idan` + 0700 dir keep others
  # out (verified: another user gets NT_STATUS_ACCESS_DENIED).
  fileSystems."/mnt/samba/idan" = {
    device = "//services-vm/idan";
    fsType = "cifs";
    options = common;
  };
}
