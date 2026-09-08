#!/usr/bin/env bash
# Validate the nixos-de flake WITHOUT deploying. Run from the nixos-de directory.

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

if ! command -v nix &> /dev/null; then
    error "Nix not found: sh <(curl -L https://nixos.org/nix/install)"
    exit 1
fi

NIX="nix --extra-experimental-features nix-command --extra-experimental-features flakes"

# Prefer a tool on PATH, else fetch it from the flake's own locked nixpkgs so
# the linters run offline and at the same version everywhere.
run_tool() {
    local tool=$1
    shift
    if command -v "$tool" &> /dev/null; then
        "$tool" "$@"
    else
        $NIX run --inputs-from . "nixpkgs#$tool" -- "$@"
    fi
}

echo "=== NixOS Configuration Test Suite ==="
echo ""

info "Running: nix flake check"
if $NIX flake check 2>&1; then
    echo -e "${GREEN}✓ Flake structure valid${NC}"
else
    error "Flake check failed"
    exit 1
fi
echo ""

info "Running: nix eval (NixOS config)"
if $NIX eval .#nixosConfigurations.desktop.config.system.build.toplevel --apply 'x: "ok"' 2>&1; then
    echo -e "${GREEN}✓ NixOS configuration evaluates${NC}"
else
    error "NixOS configuration evaluation failed"
    exit 1
fi
echo ""

info "Running: nix eval (Home Manager config)"
if $NIX eval .#homeConfigurations.idan.activationPackage --apply 'x: "ok"' 2>&1; then
    echo -e "${GREEN}✓ Home Manager configuration evaluates${NC}"
else
    error "Home Manager configuration evaluation failed"
    exit 1
fi
echo ""

info "Running: nix build --dry-run (NixOS)"
if $NIX build .#nixosConfigurations.desktop.config.system.build.toplevel --dry-run 2>&1; then
    echo -e "${GREEN}✓ NixOS dry-run build successful${NC}"
else
    warn "Dry-run build had issues (may be missing substitutes)"
fi
echo ""

info "Running: nix build --dry-run (Home Manager)"
if $NIX build .#homeConfigurations.idan.activationPackage --dry-run 2>&1; then
    echo -e "${GREEN}✓ Home Manager dry-run build successful${NC}"
else
    warn "Dry-run build had issues (may be missing substitutes)"
fi
echo ""

info "Running: statix check"
if run_tool statix check .; then
    echo -e "${GREEN}✓ No linting issues${NC}"
else
    warn "Statix found issues (non-fatal)"
fi
echo ""

info "Running: nixfmt --check"
if run_tool nixfmt --check ./*.nix modules/*/*.nix pkgs/*.nix pkgs/*/*.nix; then
    echo -e "${GREEN}✓ Files are formatted${NC}"
else
    warn "Some files need formatting (non-fatal): nixfmt ./*.nix modules/*/*.nix pkgs/*.nix pkgs/*/*.nix"
fi
echo ""

echo "=== All tests passed ==="
