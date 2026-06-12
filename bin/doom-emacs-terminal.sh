#!/usr/bin/env bash
# Doom Emacs im TERMINAL (emacsclient -nw) — robuster Weg auf Windows:
# Rendering und Input laufen komplett ueber das Terminal (Windows Terminal/
# Warp/conhost), WSLg ist nicht beteiligt. Damit existiert die gesamte
# WSLg-RAIL-Bug-Klasse (eingefrorene Updates, geparkte Fenster, Mixed-DPI-
# Maximize-Korruption — microsoft/wslg#643/#1058) hier prinzipbedingt nicht.
#
# Aufruf (Start-Menu "Doom Emacs (Terminal)" / beliebiges Terminal):
#   wsl.exe -d NixOS -- bash -lc "bash /home/nixos/nixos-config/bin/doom-emacs-terminal.sh"
#
# Verbindet zum selben systemd emacs.service-Daemon wie der GUI-Launcher —
# gleiche Buffers, gleiche Sessions, gleiche Config.

export PATH=/run/wrappers/bin:/run/current-system/sw/bin:$PATH
export COLORTERM=truecolor   # volle Theme-Farben (modus-vivendi-tinted)

cd "$HOME" || exit 1

# Kalter Distro-Boot: Doom braucht ~10s bis der Daemon-Socket antwortet.
for _ in $(seq 1 120); do
  emacsclient --timeout 2 -e t >/dev/null 2>&1 && break
  sleep 0.5
done

# TTY-Frame im aktuellen Terminal. Blockiert solange die Session laeuft —
# haelt damit auch die Distro am Leben (Terminal zu = Client weg = Distro
# darf idle-out). --alternate-editor="" startet notfalls einen Daemon.
exec emacsclient -nw --alternate-editor="" </dev/tty
