{ pkgs, ... }:

# GTK theming managed declaratively by home-manager.
#
# Without this, `~/.config/gtk-{3,4}.0/settings.ini` carry stale defaults
# (icon-theme=breeze, cursor=breeze_cursors) that don't resolve in this
# closure -> e.g. udiskie's tray menu renders "Managed devices" as a
# missing-icon placeholder.
#
# Enabling the module also activates `home.pointerCursor.gtk.enable`
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
}
