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

    noctalia = {
      url = "github:noctalia-dev/noctalia-shell";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Boot-time greeter matching noctalia's look. Separate repo from the shell:
    # it ships its own wlroots compositor so greetd can draw a GUI before login.
    noctalia-greeter = {
      url = "github:noctalia-dev/noctalia-greeter";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    zen-browser = {
      url = "github:0xc000022070/zen-browser-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Offline speech-to-text. Deliberately does NOT follow our nixpkgs: the
    # Tauri build is pinned against upstream's own nixpkgs + bun2nix pair, and
    # `handy` is not in our nixpkgs lock yet anyway.
    handy.url = "github:cjpais/Handy";

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager, stylix, nixvim, niri, noctalia, noctalia-greeter, zen-browser, handy, disko, sops-nix, ... }@inputs:
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
          noctalia-greeter.nixosModules.default
          sops-nix.nixosModules.sops
          ./modules/nixos/nvidia.nix
          ./modules/nixos/tailscale.nix
          ./modules/nixos/ssh-identities.nix
          ./modules/nixos/work-vpn.nix
          ./modules/nixos/containers.nix
          ./modules/nixos/handy.nix
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
          noctalia.homeModules.default
          zen-browser.homeModules.default
          handy.homeManagerModules.default
          ./modules/home/niri.nix
          ./modules/home/stylix.nix
          ./modules/home/nixvim.nix
          ./modules/home/foot.nix
          ./modules/home/noctalia.nix
          ./modules/home/yazi.nix
          ./modules/home/zen.nix
          ./modules/home/vscode.nix
          ./modules/home/zed.nix
          ./modules/home/obsidian.nix
          ./modules/home/handy.nix
          ./modules/home/tts.nix
          ./modules/home/excalidraw.nix
          ./modules/home/ssh-identities.nix
          ./modules/home/work-vpn.nix
        ];
      };
    };
}
