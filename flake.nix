{
  description = "BasicBastardSelfhosted — services VM (Proxmox) and headscale VPS (Hetzner)";

  # One flake for both servers, so a file can feed both hosts: the shared
  # secrets in secrets/, ssh-pubkeys.nix, and every stack's secrets beside its
  # compose file. tests/lib/sources.nix pins the harness from this lock.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      sops-nix,
      disko,
      nixos-generators,
      ...
    }@inputs:
    let
      system = "x86_64-linux";

      # Shared by the live services VM and its Proxmox image. One wrapper
      # module rather than a flat list: list-option merge order follows module
      # structure, and this shape keeps the evaluated config identical to the
      # pre-merge nixos/ flake's.
      servicesBase = [
        {
          imports = [
            sops-nix.nixosModules.sops
            ./nixos/configuration.nix
          ];
        }
      ];
    in
    {
      nixosConfigurations = {
        services-vm = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = servicesBase ++ [ ./nixos/hardware-configuration.nix ];
        };

        headscale-vps = nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = { inherit inputs; };
          modules = [
            disko.nixosModules.disko
            sops-nix.nixosModules.sops
            ./headscale-vps/disk-config.nix
            ./headscale-vps/host.nix
          ];
        };
      };

      # Both attributes must live in ONE `packages.${system}` set: Nix does not
      # merge sibling dynamic-attribute paths sharing a key.
      packages.${system} = rec {
        # Proxmox VMA image for initial provisioning of the services VM.
        proxmox-image = nixos-generators.nixosGenerate {
          inherit system;
          modules = servicesBase ++ [ ./nixos/proxmox-image.nix ];
          format = "proxmox";
        };

        default = proxmox-image;
      };
    };
}
