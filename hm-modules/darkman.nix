{ pkgs, ... }:

# darkman — dark/light mode toggle daemon (Frage 4.13 Side-Effect:
# Ctrl+Alt+T → darkman toggle wurde "auf allen meinen NixOS-Geräten"
# eingeführt; Diego erbt das gleiche Setup).
#
# Karlsruhe-Koordinaten driven automatic sun-based switching; manuelle Toggle
# über Ctrl+Alt+T (siehe hyprland.nix bind-Liste). Scripts flippen Caelestia-
# Scheme UND GTK-Theme + libadwaita/Chromium-color-scheme parallel.
#
# WICHTIG: Caelestia muss laufen für 01-caelestia.sh. Auf Diego sollte das via
# programs.caelestia.systemd.enable = true; (caelestia.nix) gewährleistet sein.

{
  services.darkman = {
    enable = true;
    settings = {
      lat = 49.0069;     # Karlsruhe (Marius-Standard auf allen Hosts)
      lng = 8.4037;
    };
    darkModeScripts = {
      "01-caelestia.sh" = ''
        PATH="$HOME/.nix-profile/bin:/run/current-system/sw/bin:$PATH" caelestia scheme set -m dark || true
      '';
      "02-gtk.sh" = ''
        ${pkgs.glib}/bin/gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
        ${pkgs.glib}/bin/gsettings set org.gnome.desktop.interface gtk-theme 'adw-gtk3-dark'
      '';
    };
    lightModeScripts = {
      "01-caelestia.sh" = ''
        PATH="$HOME/.nix-profile/bin:/run/current-system/sw/bin:$PATH" caelestia scheme set -m light || true
      '';
      "02-gtk.sh" = ''
        ${pkgs.glib}/bin/gsettings set org.gnome.desktop.interface color-scheme 'prefer-light'
        ${pkgs.glib}/bin/gsettings set org.gnome.desktop.interface gtk-theme 'adw-gtk3'
      '';
    };
  };
}
