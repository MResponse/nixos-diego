# hosts/nixos-wsl/default.nix
#
# Slimmed-down WSL host that reproduces the Doom Emacs environment from
# nixos-diego (branch `diego`) inside a NixOS-WSL distro.
#
# What this host pulls in (and ONLY this):
#   - emacs30-pgtk + libvterm + editorconfig-core-c   (inlined from modules/programming.nix)
#   - Doom build toolchain: cmake gcc gnumake libtool pkg-config clang
#     ripgrep fd nodejs_22 git                         (inlined from modules/packages.nix)
#   - services.emacs (system user daemon)             (inlined from modules/services.nix)
#
# What it deliberately does NOT pull in (vs nixos-diego):
#   modules/desktop.nix, modules/gaming.nix, modules/hyprland, nvidia, jovian,
#   sops, the full CUDA/torch/jupyter Python stack in modules/programming.nix,
#   pipewire/printing/ratbagd/usbmuxd in modules/services.nix.
# We INLINE the editor/toolchain slice rather than importing the heavy modules,
# to keep the WSL closure small and avoid GPU/Wayland units meaningless on WSL.
#
# The Doom *config* delivery is handled by hm-modules/doom.nix (imported via
# home-wsl.nix): it symlinks ~/.config/doom -> ~/nixos-config/doom. That is
# why the repo MUST be cloned to ~/nixos-config on the WSL distro.

{ pkgs, ... }:

{
  # ── Identity ────────────────────────────────────────────────────────
  # modules/hostname-safety.nix asserts networking.hostName == the flake
  # output name ("nixos-wsl"). Pin it explicitly so the assertion passes.
  networking.hostName = "nixos-wsl";

  # ── Editor + toolchain ──────────────────────────────────────────────
  environment.systemPackages = with pkgs; [
    # Emacs (Pure-GTK / Wayland build) + Doom deps. Runs over WSLg's Wayland
    # socket (WAYLAND_DISPLAY=wayland-0).
    #
    # WHY pgtk and NOT the X11 build (tested & rejected 2026-06-08): pkgs.emacs is
    # the Lucid/Xaw3d X11 toolkit. Under WSLg its Xwayland socket
    # (/tmp/.X11-unix/X0) IS present, but creating an X frame BLOCKS indefinitely
    # and wedges the daemon (emacsclient -c never returns). pgtk talks Wayland
    # directly to WSLg and renders client frames fine (verified previous session).
    # Caveat: a pgtk daemon exits if the Wayland connection drops; services.emacs
    # Restart= brings it back, so this is survivable.
    emacs30-pgtk
    libvterm                # vterm module native lib
    editorconfig-core-c     # doom :tools editorconfig

    # Doom build / search toolchain
    cmake
    gcc
    gnumake
    libtool
    pkg-config
    clang
    ripgrep                 # doom :completion / projectile (REQUIRED by doom)
    fd                      # faster file scanning for projectile
    nodejs_22               # LSP servers, copilot, etc.
    git                     # doom sync / package fetch
  ];

  # ── Emacs system daemon ─────────────────────────────────────────────
  # WSLg gotcha: there is no compositor, so the systemd *user*
  # graphical-session.target is never reached. With startWithGraphical=true
  # the daemon would be ordered After=graphical-session.target and either not
  # start or start without DISPLAY/WAYLAND_DISPLAY, making `emacsclient -c`
  # fail with "display ... can't be opened".
  #
  # Fix: start the daemon on the basic user session (startWithGraphical=false)
  # and inject the WSLg display vars into the systemd user manager so the
  # daemon inherits a working display.
  services.emacs = {
    enable = true;
    startWithGraphical = false;
    # Pure-GTK (Wayland) build — see the systemPackages note above for why the
    # X11/Lucid build was rejected (X frame creation hangs under WSLg). pgtk
    # connects to WSLg's Wayland socket and renders client frames reliably.
    package = pkgs.emacs30-pgtk;
  };

  # WSLg display env for the systemd user manager, so the emacs daemon
  # inherits a working display and `emacsclient -c` opens a frame. pgtk uses
  # WAYLAND_DISPLAY=wayland-0; DISPLAY=:0 is kept for any X11 child tools.
  # HiDPI is handled by doubling doom-font on WSL (see doom/config.el), NOT
  # GDK_SCALE (GTK ignores GDK_SCALE on pgtk and WSLg advertises scale 1.0).
  systemd.user.extraConfig = ''
    DefaultEnvironment=DISPLAY=:0 WAYLAND_DISPLAY=wayland-0
  '';

  # ── Fonts the Doom config expects ───────────────────────────────────
  # doom-font is "Iosevka"; nerd-icons needs "Symbols Nerd Font Mono";
  # symbola is Emacs' fallback glyph font. Without iosevka, GUI frame
  # creation errors ("Could not find a font ... Iosevka") and falls back
  # to a TTY frame. Curated subset of modules/fonts.nix (avoids pulling
  # the full ~70-font nerd-fonts set).
  fonts.packages = with pkgs; [
    iosevka
    symbola
    nerd-fonts.symbols-only
    noto-fonts-color-emoji
    noto-fonts-cjk-sans
  ];

  # ── WSL state version (matches NixOS-WSL default / nixos-diego) ──────
  system.stateVersion = "25.11";
}
