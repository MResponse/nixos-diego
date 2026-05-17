{ config, lib, pkgs, ... }:

# Caelestia config for Nixos-Diego — Marius's settings ported onto donvini's
# base. See HANDOVER.md for full decision history.
#
# Drop-in replacement for donvini's hm-modules/caelestia.nix.
#
# Key changes vs. donvini:
#   - appearance.transparency: 0.85 base / 0.4 layers (Tier 3 Visuals = Marius)
#   - general.idle timeouts: 1800s/2100s (Tier 3 Visuals — Marius)
#   - launcher.showOnHover = false (Marius)
#   - paths.wallpaperDir: needs adjustment for Diego (Marius has it on Syncthing
#     path; Diego may or may not have Syncthing — placeholder below, edit before
#     first switch).
#   - bar.tray.iconSubs: Discord SNI-Fix (Marius)

{
  programs.caelestia = {
    enable = true;
    systemd.enable = true;
    settings = {
      appearance.transparency = {
        enabled = true;
        base = 0.85;
        layers = 0.4;
      };

      bar.status.showBattery = true;  # Diego ist Notebook (Strix Halo) — Battery anzeigen

      # SNI tray icon substitutions
      #   - chrome_status_icon_1: Discord-Electron sendet keinen Icon-Namen
      #     (Marius — Discord-Workaround), wir patchen das PNG aus dem Discord-
      #     Bundle ein.
      #   - udiskie: meldet `drive-removable-media-usb-panel` als IconName,
      #     aber Papirus-Dark deklariert keine `panel/`-Directories (nur
      #     Papirus light tut es) → Quickshell findet das Icon nicht und
      #     zeigt den Magenta-Checker-Platzhalter. `drive-removable-media`
      #     existiert in Papirus-Dark/{16,22,24,32,64,96,128}x*/devices/.
      bar.tray.iconSubs = [
        {
          id = "chrome_status_icon_1";
          image = "file://${pkgs.discord}/opt/Discord/discord.png";
        }
        {
          id = "udiskie";
          icon = "drive-removable-media";
        }
      ];

      background.desktopClock = {
        enabled = true;
        position = "bottom-right";
      };

      general.apps = {
        terminal = [ "kitty" ];
        audio = [ "pavucontrol" ];
        explorer = [ "thunar" ];     # Marius nutzt thunar als $fileExplorer
        playback = [ "mpv" ];
      };

      # Idle/Lock-Timeouts (Tier 3 — Marius: 30min lock / 35min DPMS)
      general.idle = {
        lockBeforeSleep = true;
        inhibitWhenAudio = true;
        timeouts = [
          {
            timeout = 1800;
            idleAction = "lock";
          }
          {
            timeout = 2100;
            idleAction = "dpms off";
            returnAction = "dpms on";
          }
        ];
      };

      notifs.expire = true;
      launcher.showOnHover = false;  # Marius

      # Wallpaper-Pfad (Syncthing-Mount). Nur `paths.wallpaperDir` ist im aktuellen
      # Caelestia-Schema gültig — `services.wallpapers.path` wurde entfernt (lebte
      # in einer älteren Version, jetzt unbekannt → "Unknown option in config"-Toast).
      paths.wallpaperDir = "/home/marius/Syncthing_lighteningv1.0/undefined/Wallpaper/Wallpaper New/dark";
    };
    cli = {
      enable = true;
      settings.theme = {
        enableGtk = true;
        enableQt = true;
        enableHypr = true;
      };
    };
  };

  # ~/.config/caelestia/shell.json schreibbar machen.
  #
  # Caelestia's RootConfig::setupFileBackend (rootconfig.cpp:56) verdrahtet auto-save
  # auf jede Property-Änderung — gpuType-Detection, OSD-Slider, Wallpaper-Service-
  # Tracking, usw. HM legt die Datei aber als Nix-Store-Symlink (read-only) ab, also
  # loggt jeder Speicherversuch "Failed to write … Read-only file system" und feuert
  # einen "Failed to save config"-Toast (sichtbar nach jedem caelestia-Restart).
  #
  # Fix in zwei Phasen:
  #   1. Pre-`checkLinkTargets`: alte writable-Kopie + stale `.hm-backup` entfernen,
  #      damit HM eine saubere Ausgangslage hat. Sonst kollidiert HM beim 2. switch
  #      ("Existing file 'shell.json.hm-backup' would be clobbered…"), weil der
  #      vorige switch eine writable-Kopie + ein Backup hinterlassen hat.
  #   2. Post-`writeBoundary`: den frisch geschriebenen Nix-Store-Symlink durch eine
  #      reguläre, schreibbare Kopie mit identischem Inhalt ersetzen.
  # Nix bleibt Source of Truth — jeder `switch` überschreibt die Datei mit dem
  # aktuellen HM-Seed; Runtime-Tweaks via UI überleben bis zum nächsten Rebuild
  # (deklarativer Vertrag).
  home.activation.cleanCaelestiaShellJson = lib.hm.dag.entryBefore [ "checkLinkTargets" ] ''
    target="${config.xdg.configHome}/caelestia/shell.json"
    if [ -e "$target" ] && [ ! -L "$target" ]; then
      run rm -f "$target"
    fi
    run rm -f "$target.hm-backup"
  '';

  home.activation.makeCaelestiaShellJsonWritable = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    target="${config.xdg.configHome}/caelestia/shell.json"
    if [ -L "$target" ]; then
      src=$(readlink -f "$target")
      run rm -f "$target"
      run install -m 644 "$src" "$target"
    fi
  '';

  # Caelestia runtime dependencies (donvini-list + Marius additions)
  home.packages = with pkgs; [
    xdg-desktop-portal-gtk
    hyprpicker
    cliphist
    inotify-tools
    app2unit
    trash-cli
    adw-gtk3
    papirus-icon-theme
    nerd-fonts.jetbrains-mono
    wtype
    # Marius additions for Caelestia-Bindings:
    brightnessctl         # XF86MonBrightness fallback
    playerctl             # MPRIS fallback
    libnotify             # notify-send für Test-Notif & Screenshot
    jq                    # caelestia shell scripts
    fastfetch             # caelestia fetch
    eza                   # modern ls
  ];
}
