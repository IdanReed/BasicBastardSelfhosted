# Image-only extras for the services VM's Proxmox VMA (the root flake's
# packages.proxmox-image). tests/suites/proxmox-boot.nix imports this same file
# so the booted test image cannot drift from the shipped one.
_: {
  # Age key injection on first boot.
  services.cloud-init = {
    enable = true;
    network.enable = true;
  };

  services.qemuGuest.enable = true;
  boot.growPartition = true;

  # qmrestore resets the VM to these on every re-image, so hand-run
  # `qm set` fixes do not survive. The MAC is a fixed value from the
  # Proxmox OUI so the VM keeps one L2 identity across re-images —
  # keep it in sync with the .link match in modules/network.nix.
  proxmox.qemuConf = {
    cores = 4;
    memory = 8192;
    boot = "order=virtio0";
    net0 = "virtio=BC:24:11:5E:11:03,bridge=vmbr0,firewall=1";
  };

  # The real mounts come from hardware-configuration.nix at runtime.
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    autoResize = true;
  };
}
