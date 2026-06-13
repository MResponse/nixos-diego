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

  # RDNA 3.5 (Strix Halo gfx1151) Mesa/RADV-Tuning (Plan-0007 F8, ADR-0028):
  # - video_encode: Vulkan-Video-Encoder für Steam-Link-VR-Streaming (HEVC
  #   hardware-encoded auf-Host für Pico-4 Steam-Link). Mesa 25.2+ Pflicht.
  # - sam: Smart Access Memory (PCIe-Resizable-BAR) — full GPU-Resource-Mapping.
  #
  # Entfernt: gpl + nggc — auf RDNA 3.5 (GFX10.3+) bereits Mesa-default seit
  # Commit 52413a9; explicit-setzen war 2026-Cargo-Cult (Phoronix Mesa 25.2
  # Strix-Halo-Review). RADV-Docs: https://docs.mesa3d.org/drivers/radv.html
  environment.sessionVariables.RADV_PERFTEST = "video_encode,sam";

  # ─────────────────────────────────────────────────────────────────────
  # Proton-CachyOS (FSR4) — expose to BOTH sessions (ADR-0038 Nachtrag #1)
  #
  # modules/gaming.nix delivers proton-cachyos via
  # `programs.steam.extraCompatPackages`. Both the desktop Steam and the
  # Jovian Gaming-Mode Steam are FHS/bwrap-wrapped, and BOTH inherit the same
  # session var STEAM_EXTRA_COMPAT_TOOLS_PATHS=~/.steam/root/compatibilitytools.d
  # (set by modules/gaming.nix). The divergence is INSIDE the sandbox:
  # extraCompatPackages bakes STEAM_EXTRA_COMPAT_TOOLS_PATHS=<proton-cachyos
  # store path> into the fhsenv /etc/profile of `programs.steam.package` (the
  # DESKTOP build — proton-cachyos is in that build's closure), which
  # overrides the inherited empty-dir value before Proton is spawned. So
  # desktop Steam resolves the tool → FSR4 works.
  #
  # Jovian's Gaming Mode runs a DIFFERENT, vanilla steam fhsenv build: its
  # gamescope-session/lib/steamos/steam-launcher `exec`s a SEPARATE steam
  # derivation whose closure does NOT contain proton-cachyos and whose fhsenv
  # /etc/profile has an empty injection block. So in Gaming Mode the var stays
  # at ~/.steam/root/compatibilitytools.d — which was EMPTY → the per-game
  # forced compat tool (CompatToolMapping → "proton-cachyos-…-x86_64_v3")
  # fails to resolve → Steam exec's the raw Windows .exe ("cannot execute
  # binary file") → the game exits instantly → gamescope's xwm aborts on the
  # resulting X11 I/O error → SIGABRT takes down the whole game-mode session.
  # (Root-caused + adversarially verified 2026-06-13: console_log.txt:925 the
  # desktop run executed the proton chain; :1091/:1115 game mode ran the raw
  # exe; steam closures contain proton-cachyos 1× desktop / 0× game-mode.)
  #
  # NB: it is NOT a "wrapped vs bare" difference (both are FHS-wrapped) and
  # NOT an "env present vs absent" difference (both inherit the same session
  # var) — it is two DIFFERENT steam derivations, only one of which has
  # extraCompatPackages baked into its fhsenv /etc/profile.
  #
  # Fix: expose the tool through Steam's *native* user compat-tools dir
  # ~/.steam/root/compatibilitytools.d/, which steamclient.so scans
  # UNCONDITIONALLY in EVERY launch path (desktop fhsenv + gamepadui),
  # independent of the env var — exactly like protonup-installed GE builds.
  # The internal tool name inside compatibilitytool.vdf is unchanged
  # (proton-cachyos-…-x86_64_v3), so the existing per-game CompatToolMapping
  # keeps resolving. extraCompatPackages stays as-is (harmless: identical
  # internal name + store path; kept as the desktop safety net so this change
  # can't regress the already-working Hyprland path).
  #
  # Mechanism = user-instance tmpfiles, NOT system tmpfiles: ~/.steam/root is
  # a marius-owned symlink → ~/.local/share/Steam, and the system (root)
  # tmpfiles refuses to canonicalize through it ("unsafe path transition
  # …owned by marius → owned by root"). Running as the user, and pointing at
  # the canonical ~/.local/share/Steam path (no symlink in the chain),
  # sidesteps that entirely. Applies at user-session start; on a live switch
  # it's created out-of-band the first time, then self-heals every login.
  systemd.user.tmpfiles.rules = [
    "L+ %h/.local/share/Steam/compatibilitytools.d/proton-cachyos-fsr4 - - - - ${pkgs.proton-cachyos.steamcompattool}"
  ];

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

  # 8BitDo Ultimate 2 Wireless — USB-Device-Node-Zugriff fuer den offiziellen
  # Web-Firmware-Updater (web.8bitdo.com, WebUSB, nur Chromium). Valve's
  # 60-steam-input.rules (hardware.steam-hardware via programs.steam) deckt
  # vendor 2dc8 nur fuer hidraw + uinput ab — WebUSB braucht /dev/bus/usb.
  # Controller-Betrieb selbst braucht diese Rule NICHT (BT-DInput laeuft
  # ueber uhid/hidraw); sie existiert rein fuer Firmware-Updates ohne Windows.
  # Firmware >= v1.03 ist das Gate fuer volle Steam/SDL3-HIDAPI-Unterstuetzung
  # (Gyro, Back-Buttons, Rumble) ueber Bluetooth.
  services.udev.extraRules = ''
    SUBSYSTEM=="usb", ATTRS{idVendor}=="2dc8", TAG+="uaccess"
  '';

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
