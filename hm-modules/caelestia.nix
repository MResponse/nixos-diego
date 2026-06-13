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
      bar.status.showKbLayout = true; # Plan-0016 — DE/US Indikator + Click-Switch-Popout (Caelestia-Upstream-Feature)

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

      # Strix-Halo PD-flap toast silencer.
      # The USB-C EPR power contract (28V/140W) briefly COLLAPSES under each APU
      # power spike: sysfs sampling caught AC line-power dropping offline ~5×/45s
      # (AC=0 + BAT0=Discharging up to 46W), then re-negotiating. Each collapse
      # flips UPower.onBattery, and BatteryMonitor.qml:12-26 fires a
      # "Charger un/plugged" toast PAIR per flip → ~13 toasts/min. This silences
      # ONLY the charging toast; GameMode/VPN/audio/caps/kbLayout toasts stay on.
      # NOTE: cosmetic — the real fix is stabilising the PD contract (5A/EPR cable
      # + HP firmware + lower sustained PL). See diego-power-charging-profile memory.
      utilities.toasts.chargingChanged = false;

      launcher.showOnHover = false;  # Marius

      # Plan-0006 F2a — Caelestia-Lockscreen parallel-PAM aktivieren.
      # Quickshell PamContext × 2 (passwd + fprint) rennen gleichzeitig:
      # Passwort tippen ODER Finger touchen, schnellere gewinnt.
      # max 5 Fprint-Failversuche bevor pamFprintd-Pfad disabled fuer den
      # Lock-Cycle (Reader-noise-Schutz). pam_fprintd.so kommt aus
      # services.fprintd.enable=true (default-NixOS, ADR-0007).
      lock = {
        enableFprint = true;
        maxFprintTries = 5;
      };

      # Wallpaper-Pfad (Syncthing-Mount). Nur `paths.wallpaperDir` ist im aktuellen
      # Caelestia-Schema gültig — `services.wallpapers.path` wurde entfernt (lebte
      # in einer älteren Version, jetzt unbekannt → "Unknown option in config"-Toast).
      # Per-user-neutral so this shared module is safe for BOTH marius and the
      # acrm work account. config.home.homeDirectory = /home/marius for marius
      # (byte-identical to the old hardcoded path), /home/acrm for acrm (a
      # harmless dangling read path — acrm has no Syncthing, so the bar finds
      # no wallpaper and stays on the seeded dynamic scheme until one is set).
      paths.wallpaperDir = "${config.home.homeDirectory}/Syncthing_lighteningv1.0/undefined/Wallpaper/Wallpaper New/dark";
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

  # Bootstrap the *dynamic* (wallpaper-derived) colour scheme on a fresh device.
  #
  # The active scheme lives in RUNTIME STATE (~/.local/state/caelestia/scheme.json),
  # NOT in shell.json — the programs.caelestia HM module exposes no scheme option (it
  # only writes ~/.config/caelestia/{shell,cli}.json; verified against the upstream
  # hm-module). With nothing seeded, caelestia falls back to a fixed catppuccin/mocha
  # palette, so a from-scratch rebuild on a new machine would come up static lavender-
  # blue instead of following the wallpaper.
  #
  # We deliberately do NOT try to *derive* colours here: the dynamic scheme needs the
  # wallpaper thumbnail to already exist (caelestia only ever generates it via
  # `caelestia wallpaper`, and the shell never auto-picks a wallpaper on first launch),
  # and at activation time there is no session and no wallpaper yet. Instead we seed the
  # *intent* — a complete stock-teal palette tagged name="dynamic" (see
  # caelestia-scheme-seed.json). The shell renders the teal placeholder until the first
  # wallpaper is chosen; because the scheme is already "dynamic", `caelestia wallpaper`
  # then auto-derives the Material-You palette from that image. Verified end-to-end:
  # seed primary 9bd0cc → derived on the first `caelestia wallpaper -f`.
  #
  # COPY ONCE, ONLY IF ABSENT — opposite contract to shell.json above (which is re-
  # seeded every switch). scheme.json is live state we must not clobber: re-seeding on
  # every rebuild would wipe the wallpaper-derived colours back to teal and fight every
  # manual `caelestia scheme set`. The guard makes this a one-time fresh-device
  # bootstrap; existing installs (where scheme.json already exists) are left untouched.
  home.activation.seedCaelestiaDynamicScheme = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    scheme="${config.xdg.stateHome}/caelestia/scheme.json"
    if [ ! -e "$scheme" ]; then
      run mkdir -p "$(dirname "$scheme")"
      run install -m 644 ${./caelestia-scheme-seed.json} "$scheme"
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
