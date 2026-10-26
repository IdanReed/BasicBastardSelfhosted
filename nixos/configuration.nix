{ pkgs, lib, ... }:

let
  sshPubkeys = import ../ssh-pubkeys.nix;

  # Online resize after growing a disk in Proxmox. A binary, not a shell
  # alias: `sudo grow-disk` is the documented usage and sudo never sees an
  # alias.
  grow-disk = pkgs.writeShellScriptBin "grow-disk" ''
    set -euo pipefail
    export PATH=${
      lib.makeBinPath (with pkgs; [ cloud-utils coreutils e2fsprogs gnugrep gnused ])
    }:$PATH

    if [ "$(id -u)" -ne 0 ]; then
      echo "grow-disk must run as root" >&2
      exit 1
    fi

    case "''${1:-}" in
      srv)  part=/dev/disk/by-partlabel/state ;;
      fast) part=/dev/disk/by-partlabel/fast ;;
      slow) part=/dev/disk/by-partlabel/slow ;;
      *)    echo "Usage: grow-disk srv|fast|slow" >&2; exit 1 ;;
    esac

    dev=$(readlink -f "$part")
    disk=$(echo "$dev" | sed 's/[0-9]*$//')
    partnum=$(echo "$dev" | grep -o '[0-9]*$')

    echo "==> resizing $1: $dev (disk $disk, partition $partnum)"
    df -h "$dev" | tail -1
    echo 1 > "/sys/class/block/$(basename "$disk")/device/rescan"
    sleep 1
    growpart "$disk" "$partnum"
    resize2fs "$dev"
    df -h "$dev" | tail -1
  '';
in
{
  # Imports live here, not in flake.nix: tests/default.nix evaluates this file
  # directly, so a flake-only module would deploy while staying lint-invisible.
  imports = [
    ./modules/alerting.nix
    ./modules/backup.nix
    ./modules/ci-secrets.nix
    ./modules/deploy-plane.nix
    ./modules/docker.nix
    ./modules/firefly-cron.nix
    ./modules/forgejo-runner.nix
    ./modules/network.nix
    ./modules/renovate.nix
    ./modules/secrets.nix
  ];

  # Identity
  networking.hostName = "services-vm";
  system.stateVersion = "25.11";
  time.timeZone = "America/Chicago";
  boot.kernel.sysctl."kernel.printk" = "1 1 1 1";

  # Users
  users.users.idan = {
    isNormalUser = true;
    extraGroups = [ "wheel" "docker" ];
    shell = pkgs.bash;
    # null = keypair not generated = no access, not an eval failure.
    openssh.authorizedKeys.keys = lib.filter (k: k != null) [
      sshPubkeys.arcane-vm
    ];
  };

  # Passwordless wheel is what makes --use-remote-sudo and the backup pull
  # non-interactive; a compromised authorized key IS instant root here.
  security.sudo.wheelNeedsPassword = false;

  # SSH
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
      # UsePAM's default `yes` opens a password path PasswordAuthentication
      # does not close.
      KbdInteractiveAuthentication = false;
    };
  };

  # GPU
  # Intel Arc A380, passed through as hostpci0 (`qm set 110 --hostpci0
  # 0000:84:00,pcie=1`); media/immich map /dev/dri and the render group.
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver # VAAPI (iHD)
      vpl-gpu-rt # oneVPL / QSV
      intel-compute-runtime # OpenCL
    ];
  };
  boot.kernelModules = [ "i915" ];

  # Packages
  environment.systemPackages = [ grow-disk ] ++ (with pkgs; [
    git
    vim
    htop
    curl
    jq
    sops
    age
    cloud-utils
  ]);

  # Nix
  nix = {
    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      auto-optimise-store = true;
      # nixos-rebuild --target-host pushes unsigned store paths, which the
      # daemon accepts only from a trusted user. Wheel is already
      # root-equivalent here.
      trusted-users = [ "root" "@wheel" ];
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
  };
}
