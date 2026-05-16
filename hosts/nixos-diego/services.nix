{ pkgs, ... }:

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
  ];
}
