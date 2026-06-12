#!/usr/bin/env bash
# Doom Emacs launcher for the NixOS-WSL host, invoked by the Windows Start-Menu
# shortcut via:
#   wslg.exe -d NixOS -- bash -lc "/home/nixos/nixos-config/bin/doom-emacs-launch.sh"
#
# Architecture: launch a STANDALONE pgtk GUI emacs inside the wslg foreground
# session. We deliberately do NOT use the systemd emacs daemon + emacsclient for
# the GUI window, because under WSLg:
#   - A GUI (Wayland) surface must be created by a process running in the wslg
#     FOREGROUND session. The systemd daemon starts at boot, OUTSIDE any wslg
#     session, so frames it creates are not hosted by the foreground compositor
#     -> they come up as a black window.
#   - emacsclient -c under `bash -lc` (a pty) keeps choosing a TTY frame anyway
#     (a pgtk daemon's display is "wayland-0", which emacsclient's $DISPLAY/":0"
#     heuristic can't map, so it silently falls back to TTY = black window).
# A standalone `emacs` launched by wslg.exe is an ordinary Wayland GUI client and
# is hosted/rendered/interactive correctly.
#
# The systemd emacs daemon stays enabled for terminal use (`emacsclient -nw`/-t
# in a real terminal works fine as a TTY frame); it just isn't used here.

export WAYLAND_DISPLAY=wayland-0   # pgtk talks Wayland to WSLg
export DISPLAY=:0                  # harmless fallback for X child tools
export PATH=/run/wrappers/bin:/run/current-system/sw/bin:$PATH

exec emacs
