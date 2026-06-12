#!/usr/bin/env bash
# Doom Emacs launcher for the NixOS-WSL host, invoked by the Windows Start-Menu
# shortcut via:
#   wslg.exe -d NixOS -- bash -lc "bash /home/nixos/nixos-config/bin/doom-emacs-launch.sh"
#
# Architecture: open a maximized GUI frame on the systemd-user emacs daemon
# (emacs.service) via emacsclient.
#
# Why NOT a standalone `emacs` per launch (the design until 2026-06-12):
#   - The standalone instance ran (server-start) and stole the daemon's server
#     socket: emacs.service (Restart=always) then crash-looped every ~4s —
#     observed at restart counter 214 — and every further launch spawned yet
#     another full Emacs.
#   - Daemon frames DO render correctly under WSLg: emacsclient forwards its
#     environment (WAYLAND_DISPLAY) to the daemon, which then creates an
#     ordinary Wayland surface in the wslg session. Verified empirically
#     2026-06-12 via on-screen captures of daemon frames.
#   - The frame is created maximized at birth; resizing an EXISTING frame is
#     what triggers the WSLg repaint bug (microsoft/wslg#1058). A repaint hook
#     in doom/config.org covers later resizes, and %USERPROFILE%\.wslgconfig
#     pins WESTON_RDP_DEBUG_DESKTOP_SCALING_FACTOR=100 so Weston's HiDPI
#     scaler stays out of the pipeline (fonts are doubled in the Doom config
#     instead — see doom/config.org "Theming").

export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export DISPLAY="${DISPLAY:-:0}"
export PATH=/run/wrappers/bin:/run/current-system/sw/bin:$PATH

# Frames inherit the client's cwd — don't show /mnt/c/WINDOWS/system32.
cd "$HOME" || exit 1

# Clicking the shortcut may cold-boot the whole distro; Doom needs ~10s to
# load before the daemon socket answers. Poll up to 60s.
for _ in $(seq 1 120); do
  emacsclient --timeout 2 -e t >/dev/null 2>&1 && break
  sleep 0.5
done

# Maximize + repaint once the GUI frame exists (background helper; pgtk
# ignores an initial (fullscreen . maximized) frame parameter, and WSLg
# leaves freshly maximized frames partially painted until the next
# redisplay — microsoft/wslg#1058).
(
  for _ in $(seq 1 60); do
    sleep 0.5
    if [ "$(emacsclient --timeout 2 -e '(and (filtered-frame-list (function window-system)) t)' 2>/dev/null)" = "t" ]; then
      sleep 1.5   # let the frame finish mapping; maximizing too early gets reverted
      for _ in 1 2 3; do
        emacsclient -n -e '(let ((f (car (filtered-frame-list (function window-system))))) (set-frame-parameter f (quote fullscreen) (quote maximized)) (run-with-timer 1.0 nil (function redraw-display)))' >/dev/null 2>&1
        sleep 1.5
        [ "$(emacsclient --timeout 2 -e '(frame-parameter (car (filtered-frame-list (function window-system))) (quote fullscreen))' 2>/dev/null)" = "maximized" ] && break
      done
      break
    fi
  done
) </dev/null &

# Blocking GUI frame on the daemon — MUST NOT use -n: when this script (and
# with it wslg.exe's process tree) exits, WSL considers the distro idle and
# terminates it ~8s later, killing the daemon and the window. systemd units
# do not count towards distro lifetime. Blocking here means: window open =
# distro alive; window closed = launcher exits = distro idles out cleanly.
# </dev/null is REQUIRED: with a pty on stdin, emacsclient -c attaches a TTY
# frame to the launcher's terminal instead of creating a Wayland frame.
# --alternate-editor="" starts a daemon and retries, should emacs.service be
# down for good.
exec emacsclient -c --alternate-editor="" </dev/null
