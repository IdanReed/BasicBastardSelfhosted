{
  description = "NixOS Docker Host for Proxmox";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, sops-nix, nixos-generators, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      # Shared module used by both the live system and the image
      baseModule = { config, pkgs, lib, ... }: {
        imports = [
          sops-nix.nixosModules.sops
          ./configuration.nix
        ];
      };
    in
    {
      # NixOS configuration for nixos-rebuild switch
      nixosConfigurations.docker-host = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          baseModule
          ./hardware-configuration.nix
        ];
      };

      # Proxmox VMA image for initial provisioning
      packages.${system}.proxmox-image = nixos-generators.nixosGenerate {
        inherit system;
        modules = [
          baseModule
          # Minimal hardware config for image (real mounts come from hardware-configuration.nix at runtime)
          ({ config, pkgs, lib, ... }: {
            # Cloud-init for first boot (age key injection)
            services.cloud-init = {
              enable = true;
              network.enable = true;
            };

            # Proxmox guest agent
            services.qemuGuest.enable = true;

            # Growpart for disk expansion
            boot.growPartition = true;

            # Filesystem for image (will be replaced/extended by real disks)
            fileSystems."/" = {
              device = "/dev/disk/by-label/nixos";
              fsType = "ext4";
              autoResize = true;
            };
          })
        ];
        format = "proxmox";
      };

      # Convenience alias
      packages.${system}.default = self.packages.${system}.proxmox-image;
    };
}
