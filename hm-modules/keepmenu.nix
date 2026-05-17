{ pkgs, ... }:

# keepmenu — wofi-Picker für KeePassXC-Einträge (Frage 4.18 — donvini's
# wofi-pass war nicht mit KeePassXC kompatibel, deshalb dieser Ersatz).
#
# Keybind: Super+Shift+K → keepmenu (siehe hyprland.nix bind-Liste).
# Verschoben von Super+P, weil Super+P jetzt `power-mode cycle` auf Diego ist.
#
# Master-Passwort beim ersten Aufruf, danach 6h Cache (pw_cache_period_min = 360).
#
# Datenbank-Pfad zeigt auf den Syncthing-Eintrag den Marius auf allen Hosts
# identisch sieht. Bevor erstem Switch verifizieren dass /home/marius/Syncthing_
# lighteningv1.0/... auf Diego existiert — sonst Pfad anpassen oder Datei vom
# anderen Host kopieren.

{
  home.packages = with pkgs; [
    keepmenu
    keepassxc
    wofi              # backend für keepmenu --dmenu_command
  ];

  xdg.configFile."keepmenu/config.ini".text = ''
    [dmenu]
    dmenu_command = wofi --dmenu

    [dmenu_passphrase]
    obscure = True

    [database]
    database_1 = /home/marius/Syncthing_lighteningv1.0/Organisatorisches/MRPrivat.kdbx
    pw_cache_period_min = 360
  '';
}
