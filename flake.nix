{
  description = "BasicBastardSelfhosted — services VM, headscale VPS, desktop";

  # One flake for every host, so a file can feed several: the shared secrets in
  # secrets/, ssh-pubkeys.nix, and every stack's secrets beside its compose
  # file. tests/lib/sources.nix pins the harness from this lock's `nixpkgs`.
  #
  # Two package sets: the servers track nixos-25.11 (`nixpkgs` and everything
  # following it), the desktop tracks nixos-unstable (`nixpkgs-unstable` and the
  # inputs following that). Update them separately: `nfu` updates only the
  # desktop's; the servers' are `nix flake update nixpkgs sops-nix disko
  # nixos-generators`, followed by the test harness.
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

    # Desktop
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Same branch, separate lock: packages newer than the desktop pin (herdr).
    # Does not follow `nixpkgs-unstable` on purpose — following would make it
    # the same revision. Remove after the next `nfu` lands past 2026-10.
    nixpkgs-fresh.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };

    stylix = {
      url = "github:danth/stylix";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };

    nixvim = {
      url = "github:nix-community/nixvim";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };

    niri = {
      url = "github:sodiboo/niri-flake";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };

    noctalia = {
      url = "github:noctalia-dev/noctalia-shell";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };

    # Separate repo from the shell: it ships its own wlroots compositor so
    # greetd can draw a GUI before login.
    noctalia-greeter = {
      url = "github:noctalia-dev/noctalia-greeter";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };

    zen-browser = {
      url = "github:0xc000022070/zen-browser-flake";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };

    # Deliberately does NOT follow our nixpkgs: the Tauri build is pinned
    # against upstream's own nixpkgs + bun2nix pair.
    handy.url = "github:cjpais/Handy";

    disko-unstable = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };

    sops-nix-unstable = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };
  };

  outputs =
    {
      nixpkgs,
      sops-nix,
      disko,
      nixos-generators,
      nixpkgs-unstable,
      home-manager,
      ...
    }@inputs:
    let
      system = "x86_64-linux";

      # The desktop's modules receive `inputs` under the names they were written
      # against (inputs.niri, inputs.handy, …), with its own unstable package set.
      desktopInputs = {
        inherit (inputs)
          home-manager
          stylix
          nixvim
          niri
          noctalia
          noctalia-greeter
          zen-browser
          handy
          nixpkgs-fresh
          ;
        nixpkgs = nixpkgs-unstable;
        disko = inputs.disko-unstable;
        sops-nix = inputs.sops-nix-unstable;
      };
      desktopArgs = {
        inputs = desktopInputs;
      };
      desktopPkgs = import nixpkgs-unstable {
        inherit system;
        config.allowUnfree = true;
      };

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

        desktop = nixpkgs-unstable.lib.nixosSystem {
          inherit system;
          specialArgs = desktopArgs;
          # Explicit desktopInputs.*, never `with`: a lexical binding (the
          # servers' sops-nix, disko) silently wins over a `with` scope.
          modules = [
            ./nixos-de/configuration.nix
            ./nixos-de/hardware-configuration.nix
            ./nixos-de/disko.nix
            desktopInputs.disko.nixosModules.disko
            desktopInputs.niri.nixosModules.niri
            desktopInputs.noctalia-greeter.nixosModules.default
            desktopInputs.sops-nix.nixosModules.sops
            ./nixos-de/modules/nixos/nvidia.nix
            ./nixos-de/modules/nixos/tailscale.nix
            ./nixos-de/modules/nixos/ssh-identities.nix
            ./nixos-de/modules/nixos/sshd.nix
            ./nixos-de/modules/nixos/work-vpn.nix
            ./nixos-de/modules/nixos/containers.nix
            ./nixos-de/modules/nixos/handy.nix
          ];
        };
      };

      homeConfigurations."idan" = home-manager.lib.homeManagerConfiguration {
        pkgs = desktopPkgs;
        extraSpecialArgs = desktopArgs;
        modules = [
          ./nixos-de/home.nix
          desktopInputs.stylix.homeModules.stylix
          desktopInputs.nixvim.homeModules.nixvim
          desktopInputs.niri.homeModules.niri
          desktopInputs.noctalia.homeModules.default
          desktopInputs.zen-browser.homeModules.default
          desktopInputs.handy.homeManagerModules.default
          ./nixos-de/modules/home/niri.nix
          ./nixos-de/modules/home/stylix.nix
          ./nixos-de/modules/home/nixvim.nix
          ./nixos-de/modules/home/foot.nix
          ./nixos-de/modules/home/noctalia.nix
          ./nixos-de/modules/home/yazi.nix
          ./nixos-de/modules/home/zen.nix
          ./nixos-de/modules/home/vscode.nix
          ./nixos-de/modules/home/zed.nix
          ./nixos-de/modules/home/obsidian.nix
          ./nixos-de/modules/home/handy.nix
          ./nixos-de/modules/home/tts.nix
          ./nixos-de/modules/home/excalidraw.nix
          ./nixos-de/modules/home/ssh-identities.nix
          ./nixos-de/modules/home/work-vpn.nix
          ./nixos-de/modules/home/herdr.nix
          ./nixos-de/modules/home/claude-browser-login.nix
        ];
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
