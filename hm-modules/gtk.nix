{ pkgs, ... }:

# GTK + Qt icon-theme wiring managed declaratively by home-manager.
#
# GTK side: without this, `~/.config/gtk-{3,4}.0/settings.ini` carry stale
# defaults (icon-theme=breeze, cursor=breeze_cursors) that don't resolve in
# this closure -> e.g. udiskie's tray menu renders "Managed devices" as a
# missing-icon placeholder.
#
# Qt side: Hyprland sets `QT_QPA_PLATFORMTHEME=qt6ct`, so Qt apps (Quickshell
# / Caelestia's tray) delegate icon-theme selection to qt6ct's config. Without
# a `qt6ct.conf` Qt falls back to `hicolor` -> tray icons (udiskie's
# drive-removable-media-* etc.) render as the magenta-checker placeholder
# even though Papirus-Dark is installed. We pin Papirus-Dark in `qt6ct.conf`
# so QIcon::fromTheme lookups succeed.
#
# Enabling the GTK module also activates `home.pointerCursor.gtk.enable`
# (Bibata-Modern-Ice) in GTK apps. The base GTK theme (adw-gtk3 /
# adw-gtk3-dark) keeps being swapped at runtime by darkman.

{
  gtk = {
    enable = true;
    iconTheme = {
      name = "Papirus-Dark";
      package = pkgs.papirus-icon-theme;
    };
  };

  xdg.configFile."qt6ct/qt6ct.conf".text = ''
    [Appearance]
    icon_theme=Papirus-Dark
  '';
}
