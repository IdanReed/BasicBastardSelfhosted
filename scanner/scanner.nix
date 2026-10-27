# Minimal NixOS config for the external-security-test scanner box.
#
# Imported by nixos-infect through NIXOS_IMPORT=./scanner.nix — see
# scanner/README.md and ServerNotes/designs/security-external-testing.md.
# This box reproduces an ATTACKER OUTSIDE THE TAILNET: it owns no trust, joins
# no tailnet (phases 1-4), and only runs recon/enumeration against targets the
# operator owns.
#
# Public-safe by construction: tools + one throwaway pubkey, no targets and no
# secrets. The private target list ships separately and never lands in this
# (public-mirrored) repo — ServerNotes/secrets/scanner-targets.sops.yaml.
#
# This is NOT the desktop (nixos-de/); it is a deliberately minimal, throwaway
# host. Destroy the Vultr instance when the run is done.
{ pkgs, lib, ... }:
{
  # claude-code is the only unfree package here; allow it by name, not globally.
  nixpkgs.config.allowUnfreePredicate =
    pkg: builtins.elem (lib.getName pkg) [ "claude-code" ];

  # Non-root operator account, same throwaway key as root (nixos-infect wires
  # root's authorizedKeys from the live box; this adds the normal user).
  users.users.idan = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHdr5UyV4GrUSmp7lQNkbP3qcHpAvmY9NALDvmPlmYAF vultr-scanner-throwaway"
    ];
  };
  # Key-only login on a throwaway box — no sudo password to manage.
  security.sudo.wheelNeedsPassword = false;

  # Keys only. nixos-infect enables openssh; harden the auth methods.
  services.openssh.settings = {
    PasswordAuthentication = false;
    KbdInteractiveAuthentication = false;
  };

  # Inbound: SSH only. The scanner always initiates; nothing dials in to it.
  networking.firewall.allowedTCPPorts = [ 22 ];

  environment.systemPackages = with pkgs; [
    # Scanner toolkit — matches ServerNotes security-external-testing.md Setup 5.
    nmap # host/port/service discovery (-sS, -sV, -sC)
    testssl # TLS/SSL posture
    nuclei # templated vuln/misconfig checks (fetches templates on first run)
    subfinder # passive subdomain enumeration
    dnsx # DNS resolution/bruteforce toolkit
    gitleaks # secret scanning of the public repo checkout
    ssh-audit # SSH algorithm/hardening audit
    dnsutils # dig
    whois
    openssl
    curl
    wget
    jq
    git

    # Phase 5 ONLY. Installed, but the daemon is deliberately NOT enabled: the
    # scanner must stay off the tailnet for phases 1-4 (the external-attacker
    # surface). Join explicitly with `sudo tailscale up` as a test user when
    # phase 5 starts; `nix-shell -p` is not needed since the binary is here.
    tailscale

    # On-box agent + conveniences.
    claude-code
    tmux
    ripgrep
    fd
    htop
  ];

  # Flakes on — for the agent and any flake-based repo tooling.
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  time.timeZone = "America/New_York";
}
