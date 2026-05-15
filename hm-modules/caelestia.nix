{ pkgs, ... }:

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

      # SNI tray icon substitutions (Marius — Discord-Electron-Workaround)
      bar.tray.iconSubs = [
        {
          id = "chrome_status_icon_1";
          image = "file://${pkgs.discord}/opt/Discord/discord.png";
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
      lock.sizes.heightMult = 1.0;
      launcher.showOnHover = false;  # Marius

      # WICHTIG: Pfad anpassen bevor erster Switch!
      # Marius nutzt Syncthing für Wallpaper. Falls Syncthing auf Diego eingerichtet:
      #   /home/marius/Syncthing_lighteningv1.0/undefined/Wallpaper/Wallpaper New/dark
      # Falls noch nicht: donvini's wallpapers-Ordner als Fallback:
      paths.wallpaperDir = "/home/marius/Syncthing_lighteningv1.0/undefined/Wallpaper/Wallpaper New/dark";
      services.wallpapers.path = "/home/marius/Syncthing_lighteningv1.0/undefined/Wallpaper/Wallpaper New/dark";
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
