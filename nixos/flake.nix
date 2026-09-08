{
  description = "NixOS Docker Host for Proxmox";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

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

      # Shared by the live system and the image.
      baseModule = _: {
        imports = [
          sops-nix.nixosModules.sops
          ./configuration.nix
        ];
      };
    in
    {
      nixosConfigurations.services-vm = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          baseModule
          ./hardware-configuration.nix
        ];
      };

      # Both attributes must live in ONE `packages.${system}` set: Nix does not
      # merge sibling dynamic-attribute paths sharing a key.
      packages.${system} = rec {
        # Proxmox VMA image for initial provisioning.
        proxmox-image = nixos-generators.nixosGenerate {
          inherit system;
          modules = [
            baseModule
            (_: {
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
            })
          ];
          format = "proxmox";
        };

        default = proxmox-image;
      };
    };
}
