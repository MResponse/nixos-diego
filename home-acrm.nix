{
  inputs,
  pkgs,
  lib,
  config,
  ...
}:

# Home-manager manifest for the SECOND user `acrm` (Tier-1: Microsoft 365
# work identity on the SHARED caelestia desktop).
#
# WHY THIS FILE IS NOT home.nix:
#   The flake wires home-manager with extraSpecialArgs = { username; mail;
#   fullName; ... } GLOBAL to the HM block, all hardcoded to marius's values
#   (flake.nix:126). specialArgs take precedence over per-user _module.args
#   (verified against lib/modules.nix:723-731 + home-manager nixos/common.nix:28-34),
#   so the bare `username`/`mail`/`fullName` ARGS resolve to "marius" even
#   inside acrm's evaluation. Therefore acrm must NEVER destructure or
#   reference those args (would inherit marius's identity), and must NEVER use
#   a literal "/home/marius" or "/home/${"\${username}"}" path (would write
#   into marius's home). This file destructures ONLY { inputs, pkgs, lib,
#   config } and the modules it imports use config.home.* / "$HOME" — the
#   per-user-safe pattern.
#
#   home.username / home.homeDirectory below are set EXPLICITLY to acrm's
#   values; these AGREE with what home-manager auto-derives from the
#   users.users.acrm NixOS account (common.nix:64-65), so there is no
#   conflict — they are belt-and-suspenders, not an override.

{
  imports = [
    # Shared caelestia desktop surface (bar / launcher / lock / theming / WM /
    # terminal / shell tooling). acrm explicitly shares marius's desktop.
    # Defense-in-depth grep confirmed the ONLY marius-path contamination in
    # this whole set was caelestia.nix:97 (wallpaperDir), now patched to
    # config.home.homeDirectory.
    ./hm-modules/caelestia.nix     # bar, launcher, lock, dynamic wallpaper scheme
    ./hm-modules/hyprland.nix      # WM keybinds / input (DE+US) / window rules
    ./hm-modules/gtk.nix           # Papirus-Dark icons + Qt theme + pointerCursor.gtk wiring
    ./hm-modules/kitty.nix         # terminal
    ./hm-modules/fish.nix          # shell + abbrevs
    ./hm-modules/shell.nix         # bash / zoxide / direnv / atuin
    ./hm-modules/starship.nix      # prompt
    ./hm-modules/yazi.nix          # file manager
    ./hm-modules/zathura.nix       # PDF viewer
    ./hm-modules/mpv.nix           # media player
    ./hm-modules/helix.nix         # editor
    ./hm-modules/zellij.nix        # terminal multiplexer
    ./hm-modules/darkman.nix       # sun-based dark/light auto-toggle ($HOME-scoped)

    # acrm-specific: Microsoft 365 work apps (Edge for the Conditional-Access
    # empirical test, Teams, OneDrive). acrm-only; marius keeps his own
    # teams-for-linux in hm-modules/packages.nix (NOT deleted).
    ./hm-modules/ms365.nix

    # Caelestia Quickshell shell (the actual bar binary + QML).
    inputs.caelestia-shell.homeManagerModules.default
  ];

  # allowUnfree is already true system-wide (configuration.nix:14); mirror it
  # here for HM-eval parity (microsoft-edge / teams-for-linux are unfree),
  # matching what home.nix does.
  nixpkgs.config.allowUnfree = true;

  home = {
    # Hardcoded acrm identity — NEVER the bare `username` arg (= marius).
    # These agree with HM's auto-derived values from users.users.acrm.
    username = "acrm";
    homeDirectory = "/home/acrm";
    stateVersion = "23.05";

    # pointerCursor MUST be set here because gtk.nix relies on
    # home.pointerCursor.gtk.enable being present (gtk.nix:17-18). Same Bibata
    # cursor as marius — shared desktop look, no personal data.
    pointerCursor = {
      name = "Bibata-Modern-Ice";
      package = pkgs.bibata-cursors;
      size = 24;
      gtk.enable = true;
    };
  };

  fonts.fontconfig.enable = true;
  programs.home-manager.enable = true;

  # Default apps — same desktop handlers as marius, but DELIBERATELY WITHOUT
  # the SteamVR x-scheme-handler/vrmonitor entry (VR is marius-only and its
  # handler hardcodes /home/marius's Steam path). No SteamVR desktopEntry and
  # no openxr activation script here either.
  xdg.mimeApps.defaultApplications = {
    "application/pdf" = [ "zathura.desktop" ];
    "video/*" = [ "mpv.desktop" ];
  };

  systemd.user.startServices = "sd-switch";
}
