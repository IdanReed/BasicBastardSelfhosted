#!/usr/bin/env bash
# Test NixOS configuration without deploying
# Run from nixos-de directory

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check if nix is available
if ! command -v nix &> /dev/null; then
    error "Nix not found. Options:"
    echo "  1. Install Nix in WSL: sh <(curl -L https://nixos.org/nix/install)"
    echo "  2. Use NixOS VM/container"
    echo "  3. Copy to NixOS machine and test there"
    exit 1
fi

# Enable experimental features for flakes support
NIX="nix --extra-experimental-features nix-command --extra-experimental-features flakes"

echo "=== NixOS Configuration Test Suite ==="
echo ""

# 1. Flake check - validates flake structure
info "Running: nix flake check"
if $NIX flake check 2>&1; then
    echo -e "${GREEN}✓ Flake structure valid${NC}"
else
    error "Flake check failed"
    exit 1
fi
echo ""

# 2. Evaluate NixOS config - catches Nix evaluation errors
info "Running: nix eval (NixOS config)"
if $NIX eval .#nixosConfigurations.desktop.config.system.build.toplevel --apply 'x: "ok"' 2>&1; then
    echo -e "${GREEN}✓ NixOS configuration evaluates${NC}"
else
    error "NixOS configuration evaluation failed"
    exit 1
fi
echo ""

# 3. Evaluate Home Manager config
info "Running: nix eval (Home Manager config)"
if $NIX eval .#homeConfigurations.idan.activationPackage --apply 'x: "ok"' 2>&1; then
    echo -e "${GREEN}✓ Home Manager configuration evaluates${NC}"
else
    error "Home Manager configuration evaluation failed"
    exit 1
fi
echo ""

# 4. Dry-run build - shows what would be built without building
info "Running: nix build --dry-run (NixOS)"
if $NIX build .#nixosConfigurations.desktop.config.system.build.toplevel --dry-run 2>&1; then
    echo -e "${GREEN}✓ NixOS dry-run build successful${NC}"
else
    warn "Dry-run build had issues (may be missing substitutes)"
fi
echo ""

# 5. Optional: Run statix linter if available
if command -v statix &> /dev/null; then
    info "Running: statix check"
    if statix check . 2>&1; then
        echo -e "${GREEN}✓ No linting issues${NC}"
    else
        warn "Statix found issues (non-fatal)"
    fi
    echo ""
else
    info "Tip: Install statix for Nix linting: nix profile install nixpkgs#statix"
fi

# 6. Optional: Format check with nixfmt
if command -v nixfmt &> /dev/null; then
    info "Running: nixfmt --check"
    if nixfmt --check *.nix modules/**/*.nix 2>&1; then
        echo -e "${GREEN}✓ Files are formatted${NC}"
    else
        warn "Some files need formatting: nixfmt *.nix modules/**/*.nix"
    fi
    echo ""
fi

echo "=== All tests passed ==="
echo ""
echo "Next steps:"
echo "  1. Copy to target machine"
echo "  2. Generate hardware-configuration.nix: nixos-generate-config --show-hardware-config"
echo "  3. Build: sudo nixos-rebuild switch --flake .#desktop"
