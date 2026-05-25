{
  description = "NixOS Desktop - Niri + Stylix + Nixvim";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    stylix = {
      url = "github:danth/stylix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixvim = {
      url = "github:nix-community/nixvim";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    niri = {
      url = "github:sodiboo/niri-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    zen-browser = {
      url = "github:0xc000022070/zen-browser-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager, stylix, nixvim, niri, zen-browser, disko, sops-nix, ... }@inputs:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
      specialArgs = { inherit inputs system; };
    in
    {
      nixosConfigurations.desktop = nixpkgs.lib.nixosSystem {
        inherit system specialArgs;
        modules = [
          ./configuration.nix
          ./hardware-configuration.nix
          ./disko.nix
          disko.nixosModules.disko
          niri.nixosModules.niri
          sops-nix.nixosModules.sops
          ./modules/nixos/nvidia.nix
          ./modules/nixos/tailscale.nix
          ./modules/nixos/sops.nix
        ];
      };

      homeConfigurations."idan" = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        extraSpecialArgs = specialArgs;
        modules = [
          ./home.nix
          stylix.homeModules.stylix
          nixvim.homeModules.nixvim
          niri.homeModules.niri
          ./modules/home/niri.nix
          ./modules/home/stylix.nix
          ./modules/home/nixvim.nix
          ./modules/home/foot.nix
          ./modules/home/fuzzel.nix
          ./modules/home/yazi.nix
          ./modules/home/waybar.nix
          ./modules/home/mako.nix
          ./modules/home/zen.nix
          ./modules/home/vscode.nix
          ./modules/home/zed.nix
        ];
      };
    };
}
