{ config, pkgs, ... }:

{
  services.xserver.videoDrivers = [ "nvidia" ];

  hardware.nvidia = {
    modesetting.enable = true;
    powerManagement.enable = true;  # Preserve VRAM across suspend/resume
    open = true;                    # Open kernel modules (recommended for Turing+/RTX 4090)
    package = config.boot.kernelPackages.nvidiaPackages.production;
  };

  hardware.graphics = {
    enable = true;
    enable32Bit = true;
    # === CachyOS Performance: Hardware Video Decode ===
    extraPackages = [ pkgs.nvidia-vaapi-driver ];
  };

  environment.sessionVariables = {
    GBM_BACKEND = "nvidia-drm";
    __GLX_VENDOR_LIBRARY_NAME = "nvidia";
    NIXOS_OZONE_WL = "1";           # Electron apps use native Wayland
    __GL_GSYNC_ALLOWED = "1";
    __GL_VRR_ALLOWED = "1";
    XDG_SESSION_TYPE = "wayland";
  };

  boot.kernelParams = [
    "nvidia-drm.modeset=1"
    "nvidia-drm.fbdev=1"
  ];

  # === CachyOS Performance: NVIDIA & Audio Modprobe Options ===
  boot.extraModprobeConfig = ''
    # Audio - disable power saving to prevent crackling on desktop
    options snd-hda-intel power_save=0

    # NVIDIA optimizations
    # PAT - more efficient CPU-side memory access patterns to GPU
    options nvidia NVreg_UsePageAttributeTable=1
    # Skip zeroing GPU memory allocations - faster alloc, fine on single-user desktop
    options nvidia NVreg_InitializeSystemMemoryAllocations=0
    # Improved frame pacing via interrupt locking mode
    options nvidia NVreg_RegistryDwords=RMIntrLockingMode=1
  '';
}
