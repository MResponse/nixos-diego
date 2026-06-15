# home-wsl.nix
#
# WSL variant of home.nix. Imports ONLY the platform-agnostic hm-modules so
# the Doom Emacs workflow (doom.nix delivers ~/.config/doom ->
# ~/nixos-config/doom) comes up like nixos-diego, without dragging in anything
# that needs a Wayland compositor or desktop session.
#
# DROPPED vs ./home.nix (Wayland/desktop-only, meaningless under WSL):
#   hyprland, kitty, warp-terminal, mpv, zathura, caelestia (+ external
#   caelestia-shell HM module), keepmenu, keepassxc-fp-unlock, darkman, gtk,
#   services.nix (udiskie/syncthing/mpd/gammastep), and the
#   pointerCursor/mimeApps/SteamVR/OpenXR desktop wiring.
# SWAPPED: packages.nix -> packages-wsl.nix (drops the ~25 GUI/communication
#   apps, keeps the CLI/LSP/editor tooling Doom actually uses).
#
# KEPT (platform-agnostic): git, ssh, fish, shell, helix, packages-wsl,
#   starship, yazi, doom, zellij.
#
# home.username / homeDirectory / stateVersion preserved as in home.nix
# (stateVersion "23.05"). On NixOS-WSL the default user is `nixos`, so the
# flake passes username="nixos" and homeDirectory resolves to /home/nixos.
#
# Doom nutzt ZWEI Org-Wurzeln, beide als manuell angelegte Symlinks (KEINE
# lokalen Verzeichnisse), damit sie ueber den jeweiligen Sync-Mechanismus auf
# andere Hosts kommen:
#
#   ~/org      (privat)  -> <Syncthing>/Organisatorisches/privat_org
#       Syncthing-Topologie (Geraet <-> Phone <-> Geraet). Ist org-directory,
#       traegt org-roam/anki/reading_list und die Capture-Templates t/n.
#   ~/org-work (Arbeit)  -> <OneDrive>/Arbeitsordner/AC_Org
#       OneDrive (amiconsult). Nur Agenda + Capture w/W. Die Doom-Config
#       (defvar my/org-work-directory) bindet die Work-Wurzel nur ein, wenn
#       ~/org-work/gtd existiert (file-directory-p-Guard) — auf Hosts ohne
#       OneDrive bricht also nichts.
#
# Konkrete Pfade auf Windows-Diego (2026-06-15):
#   ln -s   "/mnt/c/Users/acrm/Storage - D/Syncthing2.0/Syncthing_lighteningv1.0/Organisatorisches/privat_org" ~/org
#   ln -sfn "/mnt/c/Users/acrm/OneDrive - amiconsult GmbH/Arbeitsordner/AC_Org" ~/org-work
# AC_Org per `attrib +P` als "always keep on this device" gepinnt, sonst
# dehydriert OneDrive die Dateien zu cloud-only und WSL/Emacs liest ins Leere.
# Auf anderen Hosts denselben Symlink auf den dortigen Sync-Pfad anlegen.
# org-agenda-files wird beim Daemon-Start EINMALIG berechnet -> nach neuen
# gtd-Dateien: systemctl --user restart emacs.service.

{
  pkgs,
  username,
  ...
}:

{
  imports = [
    ./hm-modules/git.nix
    ./hm-modules/ssh.nix
    ./hm-modules/fish.nix
    ./hm-modules/shell.nix
    ./hm-modules/helix.nix
    ./hm-modules/packages-wsl.nix
    ./hm-modules/starship.nix
    ./hm-modules/yazi.nix
    ./hm-modules/doom.nix
    ./hm-modules/zellij.nix
  ];

  nixpkgs.config.allowUnfree = true;

  home = {
    username = "${username}";
    homeDirectory = "/home/${username}";
    stateVersion = "23.05";
  };

  fonts.fontconfig.enable = true;
  programs.home-manager.enable = true;

  systemd.user.startServices = "sd-switch";
}
