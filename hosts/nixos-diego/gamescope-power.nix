# Plan-0002 §2.4 — Force `performance` power mode for the duration of a
# Gamescope session, restore the previous mode on exit.
#
# User-scope systemd service bound to `gamescope-session.target` (the Jovian
# session target). On Gamescope-start: capture the current `power-mode get`
# value into a marker file under $XDG_RUNTIME_DIR, then `power-mode set
# performance`. On Gamescope-stop (BindsTo + PropagatesStopTo from the
# upstream Jovian target): read the marker, restore the captured mode,
# remove the marker.
#
# Why this is the right knob (and not a udev rule on AC plug-in):
#   - PPD does NOT auto-downgrade `performance` on battery — verified from
#     PPD source (roast-loop agent 6). The `performance` profile is static
#     once set; PPD's v0.21 battery-aware logic only changes EPP inside the
#     `balanced` profile.
#   - HP firmware DOES cap sustained TDP based on charger wattage (100 W →
#     45 W sustained, 140 W → 60 W). This is firmware/EC-controlled and
#     transparent to Linux; no software trigger is needed.
#   - Therefore the only Linux-controllable contribution to "low clockspeeds
#     in Gamescope" is forcing `performance` mode on entry. If clockspeeds
#     are still low after that, the charger is the bottleneck.
#
# Architecture verified by roast-loop agent 3:
#   - `gamescope-session.target` exists with Requires=+BindsTo=
#     gamescope-session.service, BindsTo=graphical-session.target,
#     PropagatesStopTo=graphical-session.target
#   - BindsTo + After + WantedBy=[gamescope-session.target] is the right
#     triple for "lives exactly while Gamescope is active"
#
# `username` is passed via specialArgs in flake.nix:97 (mkDesktopHost).

{ config, lib, pkgs, username, ... }:

{
  config = lib.mkIf config.jovian.steam.enable {
    home-manager.users.${username}.systemd.user.services.diego-gamescope-performance = {
      Unit = {
        Description = "Force performance power mode for the duration of the Gamescope session";
        BindsTo = [ "gamescope-session.target" ];
        After   = [ "gamescope-session.target" ];
      };
      Service = {
        Type            = "oneshot";
        RemainAfterExit = true;

        # ExecStartPre: capture current mode BEFORE we change it. Marker lives
        # in $XDG_RUNTIME_DIR (tmpfs at /run/user/$UID, user-private, wiped at
        # reboot; set by systemd user manager via PAM-derived environment per
        # systemd.exec(5)).
        #
        # Race defense: if a marker file already exists from a previous
        # unclean shutdown of this service WITHIN the same boot session
        # (rebbot clears the tmpfs), KEEP the old marker — don't overwrite
        # it with the now-Gamescope current mode. That would corrupt the
        # restore-on-stop value.
        ExecStartPre = pkgs.writeShellScript "diego-gamescope-perf-capture" ''
          set -euo pipefail
          marker="$XDG_RUNTIME_DIR/diego-prev-power-mode"
          if [ -e "$marker" ]; then
            exit 0
          fi
          current=$(power-mode get 2>/dev/null || echo smart-sense)
          case "$current" in
            smart-sense|performance|cool|quiet|power-saver) ;;
            *) current=smart-sense ;;
          esac
          printf '%s\n' "$current" > "$marker"
        '';

        # ExecStart: the actual mode change. `power-mode set` calls
        # `systemctl start power-modes-apply@performance.service`, which is
        # polkit-allowed for wheel members (see power-modes.nix).
        ExecStart = "${pkgs.bash}/bin/bash -c 'power-mode set performance'";

        # ExecStop: restore the captured mode and clean up the marker. Runs
        # synchronously before gamescope-session.target reaches inactive;
        # Jovian's target has TimeoutStopSec=10s.
        ExecStop = pkgs.writeShellScript "diego-gamescope-perf-restore" ''
          set -euo pipefail
          marker="$XDG_RUNTIME_DIR/diego-prev-power-mode"
          prev=smart-sense
          if [ -r "$marker" ]; then
            prev=$(cat "$marker")
            rm -f "$marker"
          fi
          case "$prev" in
            smart-sense|performance|cool|quiet|power-saver) ;;
            *) prev=smart-sense ;;
          esac
          power-mode set "$prev"
        '';
      };
      Install.WantedBy = [ "gamescope-session.target" ];
    };
  };
}
