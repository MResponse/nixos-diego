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
