{ config, pkgs, ... }:

{
  virtualisation.docker = {
    enable = true;
    autoPrune.enable = true;
  };

  # UPower D-Bus daemon — Caelestia's BatteryMonitor.qml und der Bar-Battery-Indicator
  # konsumieren `Quickshell.Services.UPower`, das ohne laufenden upower.service keinen
  # displayDevice liefert (BAT0 ist im Kernel da, aber Quickshell kennt nur die UPower-
  # Abstraktion). Ohne diesen Eintrag bleibt `bar.status.showBattery = true` wirkungslos.
  # Diego-spezifisch (Laptop) — Donvini's dracula ist Tower ohne Akku und braucht das nicht.
  services.upower.enable = true;

  environment.systemPackages = with pkgs; [
    keepassxc
    thunderbird-latest
    # Polkit authentication agent — pops the Qt password dialog when an
    # action (fprintd-enroll, GUI apps requesting root, etc.) needs auth.
    # Donvini's kwallet PAM pulled this in transitively before; with kwallet
    # disabled on Diego (see default.nix), declare it explicitly. Started
    # via Hyprland exec-once in hm-modules/hyprland.nix.
    kdePackages.polkit-kde-agent-1

    # ── Strix-Halo Performance-Diagnostik (ADR-0037-Kontext) ──────────────
    # amdgpu_top: einziger vollständiger Telemetrie-Pfad auf gfx1151 —
    # hwmon hat KEIN power1_cap (ROCm #6035), amd-smi/rocm-smi melden N/A.
    # `amdgpu_top --gpu_metrics` zeigt die Throttler-Status-Bits, die
    # EC-Power-Cap vs. Thermal vs. Driver unterscheiden (Mess-Rezept:
    # Diego-OPERATIONS.md §"GPU-Performance am Netzteil").
    amdgpu_top
    # vainfo: verifiziert dass radeonsi H264/HEVC/AV1-VAAPI-Decode-Profile
    # exportiert — Voraussetzung für Hardware-Decode im Remote-Play-Client
    # (F6-Overlay darf nicht "software decoding" zeigen).
    libva-utils
    # ryzenadj: STAPM/SPPT/FPPT-Pilot oberhalb des Charger-Caps (60 W @
    # HP-140W-Lader; Chip-PL1 66 W → ~6 W sanktionierter Headroom).
    # Strix-Halo-Support seit v0.17.0 (FlyGoat/RyzenAdj#334); Zugriff via
    # ryzen_smu-Kernel-Modul (unten) statt /dev/mem — Diego-Kernel hat
    # CONFIG_IO_STRICT_DEVMEM=y. NICHTS wird automatisch angewendet; das
    # Rezept inkl. EC-Re-Assert-Check steht in OPERATIONS.md.
    ryzenadj
  ];

  # SMU-Zugriffspfad für ryzenadj (siehe Paket-Kommentar oben). Das Modul
  # exponiert nur /sys/kernel/ryzen_smu_drv — passiv bis ryzenadj es nutzt.
  # nixpkgs-Snapshot 2025-10-22 enthält den Strix-Halo-Support (amkillam/
  # ryzen_smu PR #31). Revert: beide Zeilen + ryzenadj entfernen.
  boot.extraModulePackages = [ config.boot.kernelPackages.ryzen-smu ];
  boot.kernelModules = [ "ryzen_smu" ];
}
