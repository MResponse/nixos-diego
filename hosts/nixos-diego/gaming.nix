{ lib, config, ... }:

{
  # NixOS-Built-in Steam-Wayland-Session deaktivieren (Donvinis modules/gaming.nix
  # setzt programs.steam.gamescopeSession.enable=true). Jovian liefert eine
  # eigene Gaming-Mode-Session und beide würden um services.displayManager.sessionPackages
  # konkurrieren.
  programs.steam.gamescopeSession.enable = lib.mkForce false;

  # NixOS-Standalone-gamescope deaktivieren — Donvinis modules/gaming.nix setzt
  # programs.gamescope.enable=true, was ein zweites gamescope-Binary in
  # environment.systemPackages installiert (Jovians /run/wrappers/bin/gamescope
  # gewinnt im PATH, aber Closure-Bloat ~250 MB und latentes Konflikt-Risiko
  # falls Donvini je capSysNice mitsetzt). Jovian's eigenes gamescope-Setup
  # ist das einzig genutzte.
  programs.gamescope.enable = lib.mkForce false;

  # Lossless Scaling Frame Gen (Vulkan-Layer) auf iGPU = Selbst-Kannibalisierung:
  # CPU+iGPU+FrameGen konkurrieren um die geteilte LPDDR5X-Bandwidth (~256 GB/s).
  # Plus globaler Vulkan-Layer-Init bei jedem Vulkan-Client (auch Browser, Caelestia).
  # Auf dGPU sinnvoll, auf Strix-Halo-iGPU netto-negativ — bei Bedarf pro-Spiel
  # via LSFG_PROCESS=1 reaktivierbar (Layer bleibt im Store).
  services.lsfg-vk.enable = lib.mkForce false;

  # RDNA 3.5 (Strix Halo gfx1151) Mesa/RADV-Tuning:
  # - gpl: Graphics Pipeline Library — kein Shader-Compilation-Stutter beim
  #   ersten Spielladen
  # - nggc: Next-Gen-Geometry Culling — schneller geometry-throughput
  # - sam: Smart Access Memory — full GPU-Resource-Mapping über PCIe
  environment.sessionVariables.RADV_PERFTEST = "gpl,nggc,sam";

  jovian = {
    steam = {
      enable = true;
      autoStart = false;
      # Verweis statt String-Literal: wenn Donvini je auf UWSM umstellt
      # (defaultSession="hyprland-uwsm"), zieht Diego automatisch mit.
      desktopSession = config.services.displayManager.defaultSession;
      user = "marius";
    };

    hardware.has.amd.gpu = true;

    # SteamOS-Defaults granular whitelisten statt useSteamOSConfig=true:
    # Default zieht audit=0, amd_iommu=off (DMA-Risiko via USB4!),
    # offene NetworkManager-Polkit-Rule, screen-reader Default-on,
    # /sys/class/dmi/id/product_serial relaxed auf wheel-readable, u.a.
    # — alles SteamDeck-spezifisch und auf einem Multi-Purpose-Laptop falsch.
    steamos = {
      useSteamOSConfig = lib.mkForce false;
      enableEarlyOOM = true;       # OOM-killer verhindert System-Freeze
      enableSysctlConfig = true;   # Gaming-sysctls (vm.max_map_count etc.)
    };
  };

  # galileo-mura-extractor (Steam Deck OLED Pixel-Uniformity-Calibration)
  # setuid-root durch Jovian, auf Strix Halo funktionslos — kein OLED-Display,
  # keine Mura-Daten. setuid-Bit weg = keine Privilege-Eskalations-Surface;
  # Binary bleibt im PATH (würde ohne Steam-Deck-Hardware eh nichts machen).
  security.wrappers.galileo-mura-extractor.setuid = lib.mkForce false;

  # Audit-Subsystem und AMD-IOMMU explizit zurück auf NixOS-Defaults
  # (Jovian würde mit useSteamOSConfig=true beide deaktivieren).
  # iommu=pt = passthrough-mode, schützt vor DMA-Attacks via USB4/Thunderbolt
  # ohne signifikanten Performance-Cost.
  boot.kernelParams = [
    "audit=1"
    "amd_iommu=on"
    "iommu=pt"
  ];
}
