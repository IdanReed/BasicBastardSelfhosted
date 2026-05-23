# Declarative disk partitioning for NixOS
#
# IMPORTANT: Before running disko, identify the correct drive:
#
#   # List drives with sizes and models
#   lsblk -d -o NAME,SIZE,MODEL
#
#   # Get stable by-id paths (includes model + serial)
#   ls -la /dev/disk/by-id/ | grep -v part
#
#   # Example output:
#   # nvme-Samsung_SSD_990_PRO_2TB_S6Z2NF0W123456 -> ../../nvme0n1
#   # ata-WDC_WD2003FZEX-00SRLA0_WD-123456789    -> ../../sda
#
# Then update the 'device' field below with YOUR drive's by-id path.
#
# To preview without making changes:
#   sudo nix --experimental-features "nix-command flakes" run github:nix-community/disko -- --mode disko --dry-run ./disko.nix
#
# To actually partition (DESTRUCTIVE - will wipe the specified drive):
#   sudo nix --experimental-features "nix-command flakes" run github:nix-community/disko -- --mode disko ./disko.nix

{ lib, ... }:

let
  # ============================================================================
  # CHANGE THIS to your target drive's /dev/disk/by-id/ path
  # ============================================================================
  targetDisk = "/dev/disk/by-id/CHANGE_ME_TO_YOUR_DRIVE_ID";
  # Example: "/dev/disk/by-id/nvme-Samsung_SSD_990_PRO_2TB_S6Z2NF0W123456"
  # ============================================================================
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
              type = "EF00";  # EFI System Partition
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "umask=0077" ];
              };
            };
            root = {
              size = "100%";  # Use remaining space
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
