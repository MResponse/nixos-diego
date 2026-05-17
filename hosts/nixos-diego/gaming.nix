{ lib, config, pkgs, ... }:

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
      # NOTE: `jovian.steam.desktopSession` is deliberately NOT set here.
      # autostart.nix:106 reads cfg.desktopSession exactly once, inside
      # `mkIf cfg.autoStart` — with autoStart=false it's dead Nix code and
      # Jovian itself emits an eval warning if we set it. The runtime
      # mechanism is `steamosctl set-default-desktop-session`, which writes
      # to ~/.local/state/steamos-manager/state.toml; we replicate Jovian's
      # oneshot below (`systemd.user.services.set-steamos-desktop-session`),
      # un-gated on autoStart so the value propagates on every login.
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

  # AMD-IOMMU explizit auf NixOS-Default (Jovian würde mit useSteamOSConfig=true
  # deaktivieren). iommu=pt = passthrough-mode, schützt vor DMA-Attacks via
  # USB4/Thunderbolt ohne signifikanten Performance-Cost.
  #
  # `audit=1` wurde ENTFERNT: NixOS aktiviert keinen auditd-Userspace-Daemon
  # mit (`security.auditd.enable` default false). Mit `audit=1` füllt der
  # Kernel kauditd's 64-Slot-Hold-Queue innerhalb von Sekunden, ohne dass
  # irgendwer drain't — Resultat ist die Flut von `audit: kauditd hold queue
  # overflow` in dmesg/journalctl -k (+ stiller `audit_lost`-Increment).
  # Falls Audit-Logging je gebraucht wird: `security.auditd.enable = true;`
  # UND `audit=1` zurück hinzufügen — die beiden gehören paarweise oder gar
  # nicht. Reines `audit=0` wäre überflüssig; ohne Kernel-Param landet das
  # Subsystem im "compiled-in but inactive"-Zustand, der nichts emittiert.
  boot.kernelParams = [
    "amd_iommu=on"
    "iommu=pt"
  ];

  # Pin the default desktop session for steamos-manager. Without this,
  # the Power-Menu's "Switch to Desktop" fails with
  # `I/O error: No such file or directory` because steamos-manager's
  # state file `~/.local/state/steamos-manager/state.toml` doesn't exist
  # yet. Jovian's autostart.nix:106 provisions an identical oneshot but
  # only under `mkIf cfg.autoStart`. We're on autoStart=false so we
  # replicate it ourselves, un-gated. Value is derived from
  # services.displayManager.defaultSession, which Diego pins to
  # "hyprland-uwsm" in default.nix (ADR-0017) so the Gamescope→Hyprland
  # return path lands in the UWSM-managed session that switch-to-game-mode
  # also depends on. Touching defaultSession upstream now propagates here
  # automatically without code change.
  systemd.user.services.set-steamos-desktop-session = {
    description = "Pin steamos-manager default desktop session";
    wants = [ "steamos-manager.service" ];
    after = [ "steamos-manager.service" ];
    wantedBy = [ "graphical-session.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart =
        "${pkgs.steamos-manager}/bin/steamosctl set-default-desktop-session "
        + "${config.services.displayManager.defaultSession}.desktop";
    };
  };
}
