# Hardware configuration for NixOS desktop
#
# Filesystems are managed by disko (see disko.nix)
# Other hardware settings can be customized here after generation with:
#   nixos-generate-config --show-hardware-config

{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.initrd.availableKernelModules = [ "nvme" "xhci_pci" "ahci" "usbhid" "sd_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-amd" ];  # Change to "kvm-intel" for Intel CPU
  boot.extraModulePackages = [ ];

  # Filesystems managed by disko - do not define here
  # See disko.nix for partition layout

  networking.useDHCP = lib.mkDefault true;
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
