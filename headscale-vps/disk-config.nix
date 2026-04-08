# Declarative disk partitioning for Hetzner Cloud
# Hetzner x86_64 VPS uses legacy boot (MBR), not UEFI
{
  disko.devices = {
    disk = {
      main = {
        type = "disk";
        device = "/dev/sda";  # Hetzner Cloud primary disk
        content = {
          type = "gpt";
          partitions = {
            # BIOS boot partition (required for legacy boot)
            boot = {
              size = "1M";
              type = "EF02";  # BIOS boot
            };
            # Root partition
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
