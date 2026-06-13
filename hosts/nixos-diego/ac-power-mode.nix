# AC-coupled automatic power mode (Goal 2026-06-12, ADR-0037).
#
# Marius's explicit requirement: "max performance of the machine when the
# laptop is charging". This module couples the five-mode power system
# (power-modes.nix, ADR-0012) to the AC adapter state:
#
#   AC plugged in  → power-mode `performance`
#   AC unplugged   → power-mode `smart-sense` (the balanced default)
#
# Relationship to gamescope-power.nix's header note ("why NOT a udev rule on
# AC plug-in"): that note answered a DIFFERENT question — whether a udev rule
# was needed to keep `performance` from degrading on battery (it isn't; ppd
# never auto-downgrades a static profile). It did not address auto-ESCALATION
# on plug-in, which is what Marius asked for now. The two mechanisms compose:
# gamescope-power forces `performance` during a Gamescope session regardless
# of AC; this module sets the *baseline* mode from the charger state.
#
# Semantics deliberately EVENT-based, not state-enforcing:
#   - We react to AC plug/unplug events (and once at boot). A manual
#     `power-mode set quiet` while plugged in STAYS until the next
#     plug/unplug event — the automation never fights an explicit choice
#     mid-state. Deterministic rule: every plug event lands in
#     `performance`, every unplug event in `smart-sense`, every boot
#     re-evaluates from the live AC state.
#
# Debounce: the HP ZBook G1a PD firmware is over-sensitive at the 20V↔28V
# (SPR↔EPR) boundary and can flap AC-online 1→0→1 with EPR chargers (see
# the fwupd block in default.nix + memory diego-power-charging-profile).
# A naive udev→apply pipeline would thrash modes on every flap. Defense:
#   1. `sleep 3` before reading the final AC state (flaps settle in <1s);
#   2. a /run marker dedupes — only an actual 0↔1 *transition* applies a
#      mode, repeated events with the same settled state are no-ops.
#
# Power-envelope reality check (why this module alone can't max GPU clocks):
# the HP EC caps sustained package power based on the NEGOTIATED CHARGER
# WATTAGE (~45 W sustained on a 100 W charger, ~60 W on the HP 140 W EPR
# charger; PL1 66 W / PL2 81 W chip caps). `performance` mode is the maximum
# Linux can request — the charger decides the rest. See OPERATIONS.md
# §"GPU-Performance am Netzteil" for the measurement recipe.
#
# Revert: remove the `./ac-power-mode.nix` import from default.nix.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  evalScript = pkgs.writeShellScript "diego-ac-power-mode-eval" ''
    set -euo pipefail

    # Debounce PD-renegotiation flaps (see header). All queued udev events
    # within this window collapse into one settled-state evaluation.
    sleep 3

    online=$(cat /sys/class/power_supply/AC/online)
    marker=/run/diego-ac-power-mode/last

    last=""
    [ -r "$marker" ] && last=$(cat "$marker")

    # Same settled state as last evaluation → not a transition → keep
    # whatever mode is active (incl. manual overrides).
    if [ "$online" = "$last" ]; then
      exit 0
    fi
    printf '%s' "$online" > "$marker"

    if [ "$online" = "1" ]; then
      mode=performance
    else
      mode=smart-sense
    fi

    echo "diego-ac-power-mode: AC online=$online → power mode '$mode'"
    exec systemctl start "power-modes-apply@$mode.service"
  '';
in
{
  config = lib.mkIf config.services.powerModes.enable {

    # Marker directory on tmpfs — empty after every boot, so the first
    # evaluation (boot) always applies the AC-derived mode.
    systemd.tmpfiles.rules = [
      "d /run/diego-ac-power-mode 0755 root root - -"
    ];

    # One service, two triggers: boot (chained off power-modes-restore via
    # ExecStartPost below, so the AC-derived mode wins over the restored one)
    # and udev change events. Deliberately NO wantedBy/after wiring of its
    # own: power-modes-restore has `after = multi-user.target`, so a unit
    # that is both WantedBy=multi-user.target and After=restore creates an
    # ordering cycle (observed 2026-06-12: systemd deleted the restore job
    # to break it — which would have silently disabled mode-restore at boot).
    systemd.services.diego-ac-power-mode = {
      description = "Set power mode from AC adapter state (performance on AC, smart-sense on battery)";
      # PD-flap storms may re-trigger in bursts; never rate-limit into failure.
      unitConfig.StartLimitIntervalSec = 0;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.bash}/bin/bash ${evalScript}";
      };
    };

    # Boot trigger: after the restore oneshot has applied the last-known
    # mode, kick the AC evaluation (--no-block keeps restore's stop job
    # independent of our 3 s debounce). Merges into the unit defined in
    # power-modes.nix.
    systemd.services.power-modes-restore.serviceConfig.ExecStartPost =
      "${pkgs.systemd}/bin/systemctl start --no-block diego-ac-power-mode.service";

    # `--no-block`: udev RUN+= must not wait for the 3 s debounce sleep.
    # ATTR{type}=="Mains" instead of KERNEL=="AC" — robust against the EC
    # renaming the supply (ADP1/ACAD variants seen across HP firmware).
    services.udev.extraRules = ''
      SUBSYSTEM=="power_supply", ATTR{type}=="Mains", ACTION=="change", RUN+="${pkgs.systemd}/bin/systemctl start --no-block diego-ac-power-mode.service"
    '';
  };
}
