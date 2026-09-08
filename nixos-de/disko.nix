# Declarative disk partitioning. `targetDisk` matters only when disko RUNS —
# the generated fileSystems mount by partlabel — but a wrong value there wipes
# the wrong disk, so find the stable path first:
#
#   ls -la /dev/disk/by-id/ | grep -v part
#   sudo nix run github:nix-community/disko -- --mode disko --dry-run ./disko.nix
#   sudo nix run github:nix-community/disko -- --mode disko ./disko.nix   # DESTRUCTIVE
{ ... }:

let
  # CHANGE THIS to the target drive's /dev/disk/by-id/ path, e.g.
  # "/dev/disk/by-id/nvme-Samsung_SSD_990_PRO_2TB_S6Z2NF0W123456"
  targetDisk = "/dev/disk/by-id/CHANGE_ME_TO_YOUR_DRIVE_ID";
in
{
  disko.devices = {
    disk = {
      main = {
        type = "disk";
        device = targetDisk;
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              priority = 1;
              name = "ESP";
              size = "512M";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "umask=0077" ];
              };
            };
            root = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
          };
        };
      };
    };
  };
}
