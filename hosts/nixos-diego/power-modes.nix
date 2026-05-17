# Five-mode declarative power management for Nixos-Diego
# (HP ZBook Ultra G1a, AMD Ryzen AI Max+ PRO 395 / Strix Halo).
#
# Replicates HP's Windows myHP modes (Smart Sense / Performance / Cool / Quiet /
# Power Saver) on Linux by layering EPP + boost + scaling-cap + GPU-DPM
# overrides on top of power-profiles-daemon (which itself drives the firmware
# platform_profile). ppd remains the bedrock — no replacement, no patches.
#
# Design rationale lives in shared-claude/Softwareprojekte/Nixos-Diego/adr/
# 0024-five-mode-power-system.md. Plan: /root/.claude/plans/zesty-hatching-
# treasure.md.
#
# Host-local for v1 (no other host imports this yet). Graduate to /modules
# once a second host actually wants it.

{
  config,
  lib,
  pkgs,
  username,
  ...
}:

let
  cfg = config.services.powerModes;

  # Whitelist for value validation inside the apply script. Keep these in sync
  # with the option enums below.
  validModeNames = [
    "smart-sense"
    "performance"
    "cool"
    "quiet"
    "power-saver"
  ];

  # The apply script — privileged, runs as root via the templated unit. The
  # only ExecStart of power-modes-apply@<mode>.service. Reads its inputs from
  # /etc/power-modes/<mode>.env (declared below). Whitelists every value
  # before touching sysfs (defense-in-depth on top of Polkit + CLI).
  applyScript = pkgs.writeShellScript "power-modes-apply" ''
    set -euo pipefail

    # 1. Mode-name whitelist. Polkit + CLI already filter, this is the third
    #    layer — and the only one that runs as root, so it has the final say.
    case "''${MODE:-}" in
      smart-sense|performance|cool|quiet|power-saver) ;;
      *) echo "power-modes-apply: invalid MODE='$MODE'" >&2; exit 1 ;;
    esac

    # 2. Pre-enable the global cpufreq/boost gate. ppd internally manages
    #    per-policy /sys/devices/system/cpu/cpufreq/policy*/boost when it
    #    switches profile; the kernel rejects (EINVAL) per-policy boost
    #    writes when the global cpufreq/boost knob is 0. If we don't
    #    pre-enable, `powerprofilesctl set` fails the moment we transition
    #    out of any mode that disabled global boost (Quiet / Power Saver).
    #    The final-state global-boost write in step 5 below sets the target
    #    afterwards, so this pre-enable is transient.
    if [[ -w /sys/devices/system/cpu/cpufreq/boost ]]; then
      printf '1' > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true
    fi

    # 3. ppd (blocking) — it owns platform_profile and the ppd-level EPP
    #    default. Settle 50 ms before our overrides so ppd's own writes
    #    don't race us.
    case "''${PPD_PROFILE:-}" in
      power-saver|balanced|performance) ;;
      *) echo "power-modes-apply: invalid PPD_PROFILE='$PPD_PROFILE'" >&2; exit 1 ;;
    esac
    ${pkgs.power-profiles-daemon}/bin/powerprofilesctl set "$PPD_PROFILE"
    sleep 0.05

    # 4. EPP override (fan-out via tee glob — 1 write instead of 16). Empty
    #    EPP_OVERRIDE means "no override, let ppd's default stand".
    if [[ -n "''${EPP_OVERRIDE:-}" ]]; then
      case "$EPP_OVERRIDE" in
        default|performance|balance_performance|balance_power|power) ;;
        *) echo "power-modes-apply: invalid EPP_OVERRIDE='$EPP_OVERRIDE'" >&2; exit 1 ;;
      esac
      # shellcheck disable=SC2086
      printf '%s' "$EPP_OVERRIDE" \
        | tee /sys/devices/system/cpu/cpufreq/policy*/energy_performance_preference \
          >/dev/null
    fi

    # 5. Final CPU boost — kernel-standard cpufreq/boost global toggle.
    #    Sets the target value after ppd (which itself manages per-policy
    #    boost during profile switch). The amd_pstate/cpb_boost knob isn't
    #    exposed on this kernel; cpufreq/boost is the documented stable
    #    path for amd_pstate=active.
    case "''${BOOST:-}" in
      0|1) ;;
      *) echo "power-modes-apply: invalid BOOST='$BOOST'" >&2; exit 1 ;;
    esac
    if [[ -w /sys/devices/system/cpu/cpufreq/boost ]]; then
      printf '%s' "$BOOST" > /sys/devices/system/cpu/cpufreq/boost
    fi

    # 6. scaling_max_freq cap, only if SCALING_MAX_PCT set (empty = no cap).
    if [[ -n "''${SCALING_MAX_PCT:-}" ]] \
       && [[ -r /sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq ]]; then
      if ! [[ "$SCALING_MAX_PCT" =~ ^[0-9]+$ ]] \
         || (( SCALING_MAX_PCT < 10 || SCALING_MAX_PCT > 100 )); then
        echo "power-modes-apply: invalid SCALING_MAX_PCT='$SCALING_MAX_PCT'" >&2
        exit 1
      fi
      max=$(< /sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq)
      target=$(( max * SCALING_MAX_PCT / 100 ))
      printf '%s' "$target" \
        | tee /sys/devices/system/cpu/cpufreq/policy*/scaling_max_freq \
          >/dev/null
    else
      # No cap requested → restore to firmware max so a previous capped mode
      # doesn't bleed through.
      if [[ -r /sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq ]]; then
        max=$(< /sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq)
        printf '%s' "$max" \
          | tee /sys/devices/system/cpu/cpufreq/policy*/scaling_max_freq \
            >/dev/null
      fi
    fi

    # 7. GPU DPM. Defaults to "auto" everywhere on Strix Halo — keeping the
    #    knob exposed for future tuning, but RDNA 3.5 drops idle p-states
    #    autonomously, so "low" is marginal and risks compositor stutter.
    case "''${GPU_DPM:-auto}" in
      auto|low|high|manual) ;;
      *) echo "power-modes-apply: invalid GPU_DPM='$GPU_DPM'" >&2; exit 1 ;;
    esac
    for f in /sys/class/drm/card*/device/power_dpm_force_performance_level; do
      [[ -w "$f" ]] && printf '%s' "''${GPU_DPM:-auto}" > "$f" || true
    done

    # 8. Persist current mode. State dir is created by systemd-tmpfiles.
    printf '%s\n' "$MODE" > /var/lib/power-modes/current

    # 9. Friendly log line in the journal.
    echo "power-modes-apply: mode=$MODE ppd=$PPD_PROFILE epp=''${EPP_OVERRIDE:-default} boost=$BOOST cap=''${SCALING_MAX_PCT:-none}% gpu=''${GPU_DPM:-auto}"
  '';

  # User-facing CLI. Validates input, kicks off the templated unit (Polkit
  # lets wheel do this without a password), then notifies on success.
  powerModeCli = pkgs.writeShellApplication {
    name = "power-mode";
    runtimeInputs = with pkgs; [
      libnotify
      systemd
      coreutils
      power-profiles-daemon
    ];
    text = ''
      set -euo pipefail

      STATE_FILE=/var/lib/power-modes/current
      ENV_DIR=/etc/power-modes

      # Modes in ascending order of system performance. Used by `cycle`
      # and printed in `usage` so the order matches the F1..F5 keybinds.
      ORDER=(power-saver quiet cool smart-sense performance)

      usage() {
        cat <<'EOF'
      power-mode — switch Diego's power mode

      Usage:
        power-mode list            list modes, current starred
        power-mode get             print current mode
        power-mode cycle           advance to the next mode (ascending power, wraps)
        power-mode set <mode>      apply <mode>
        power-mode show            dump live sysfs values

      Modes (ascending power): power-saver | quiet | cool | smart-sense | performance
      EOF
      }

      cmd_get() {
        if [[ -r "$STATE_FILE" ]]; then
          cat "$STATE_FILE"
        else
          echo "(none — restore service not yet run)"
        fi
      }

      cmd_list() {
        local current=""
        [[ -r "$STATE_FILE" ]] && current=$(cat "$STATE_FILE")
        for f in "$ENV_DIR"/*.env; do
          [[ -e "$f" ]] || continue
          local mode
          mode=$(basename "$f" .env)
          if [[ "$mode" == "$current" ]]; then
            printf '  * %s\n' "$mode"
          else
            printf '    %s\n' "$mode"
          fi
        done
      }

      cmd_set() {
        local mode="$1"
        case "$mode" in
          smart-sense|performance|cool|quiet|power-saver) ;;
          *)
            echo "power-mode: unknown mode '$mode'" >&2
            echo "Valid: smart-sense performance cool quiet power-saver" >&2
            exit 1
            ;;
        esac
        if ! systemctl start "power-modes-apply@$mode.service"; then
          echo "power-mode: failed to apply '$mode' — check 'journalctl -u power-modes-apply@$mode.service'" >&2
          exit 1
        fi
        # Capitalize first letter for the notification title
        local pretty="''${mode^}"
        pretty="''${pretty//-/ }"
        # Mode-specific notification icon — absolute path into the bundled
        # PowerModes theme. notify-send → freedesktop notification spec → the
        # notifier (Caelestia/dunst/etc.) loads the file directly.
        local icon="${modeIcons}/share/icons/PowerModes/scalable/status/$mode.svg"
        notify-send -u low -i "$icon" "Power mode: $pretty" "Now active" || true
      }

      cmd_cycle() {
        local current=""
        [[ -r "$STATE_FILE" ]] && current=$(cat "$STATE_FILE")

        local next=""
        local i
        for i in "''${!ORDER[@]}"; do
          if [[ "''${ORDER[$i]}" == "$current" ]]; then
            next="''${ORDER[$(( (i + 1) % ''${#ORDER[@]} ))]}"
            break
          fi
        done
        # No valid current state — start the cycle at the weakest mode.
        [[ -z "$next" ]] && next="''${ORDER[0]}"

        cmd_set "$next"
      }

      cmd_show() {
        # GPU card numbering is kernel-assigned; on the ZBook G1a it's card1,
        # but stay robust by picking the first amdgpu DRM card with a DPM
        # control file.
        local gpu_dpm="n/a"
        for f in /sys/class/drm/card*/device/power_dpm_force_performance_level; do
          if [[ -r "$f" ]]; then
            gpu_dpm=$(cat "$f")
            break
          fi
        done
        echo "Mode:                  $(cmd_get)"
        echo "ppd profile:           $(powerprofilesctl get 2>/dev/null || echo n/a)"
        echo "platform_profile:      $(cat /sys/firmware/acpi/platform_profile 2>/dev/null || echo n/a)"
        echo "EPP (policy0):         $(cat /sys/devices/system/cpu/cpufreq/policy0/energy_performance_preference 2>/dev/null || echo n/a)"
        echo "Governor (policy0):    $(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null || echo n/a)"
        echo "boost (cpufreq):       $(cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || echo n/a)"
        echo "scaling_max_freq (p0): $(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq 2>/dev/null || echo n/a) / $(cat /sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq 2>/dev/null || echo n/a)"
        echo "GPU DPM:               $gpu_dpm"
      }

      case "''${1:-}" in
        list)  cmd_list ;;
        get)   cmd_get ;;
        show)  cmd_show ;;
        cycle) cmd_cycle ;;
        set)
          shift || true
          [[ $# -eq 1 ]] || { usage; exit 2; }
          cmd_set "$1"
          ;;
        ""|-h|--help|help) usage ;;
        *) usage; exit 2 ;;
      esac
    '';
  };

  # Restore script — system service After=power-profiles-daemon. Reads the
  # state file, validates against whitelist, falls back to defaultMode if
  # the state is corrupted or missing, then triggers the apply unit.
  restoreScript = pkgs.writeShellScript "power-modes-restore" ''
    set -euo pipefail
    STATE_FILE=/var/lib/power-modes/current
    DEFAULT_MODE=${lib.escapeShellArg cfg.defaultMode}

    if [[ -r "$STATE_FILE" ]]; then
      mode=$(cat "$STATE_FILE")
    else
      mode=""
    fi
    case "$mode" in
      smart-sense|performance|cool|quiet|power-saver) ;;
      *)
        echo "power-modes-restore: invalid or missing state ('$mode'), falling back to $DEFAULT_MODE" >&2
        mode="$DEFAULT_MODE"
        ;;
    esac
    exec ${pkgs.systemd}/bin/systemctl start "power-modes-apply@$mode.service"
  '';

  # 5 SVG icons packaged as a freedesktop icon theme — one per mode. Symbolic
  # style, `fill="currentColor"` so the bar's icon-recolour picks them up.
  #
  # Structure: both freedesktop-conformant (scalable/status/<mode>.svg with a
  # valid index.theme) AND a flat layer of extensionless symlinks at the
  # theme root. The flat layer is a workaround for two co-located bugs in
  # the rendering stack — see "Why the flat extensionless symlinks" below.
  #
  # Distinct shapes so smart-sense (balanced ppd) and cool (also balanced) are
  # visually distinguishable at a glance — that's the whole point of the bar
  # indicator, otherwise hovering the battery popout would suffice.
  #
  # ── Why the flat extensionless symlinks (ADR-0016 §"Offener Punkt") ──
  #
  # The SNI tray-slot is rendered by Caelestia -> Quickshell -> QtQuick.Image.
  # The Python indicator publishes `IconName="quiet"` and `IconThemePath=<this
  # theme>`. The freedesktop spec says hosts resolve that via XDG icon-theme
  # lookup (read index.theme, search `scalable/status/quiet.svg`, etc.).
  #
  # Neither layer does that. Both naively join `${path}/${name}`:
  #   - Caelestia utils/Icons.qml getTrayIcon():
  #       icon = Qt.resolvedUrl(`${path}/${name.slice(name.lastIndexOf("/")+1)}`)
  #       -> builds `/.../PowerModes/quiet`
  #   - Quickshell src/core/iconimageprovider.cpp requestPixmap():
  #       path = QString("/%1/%2").arg(path, iconName.sliced(...))
  #       -> falls back to `QPixmap("/.../PowerModes/quiet")` if QIcon::fromTheme misses
  #
  # No `.svg` appended, no `scalable/status/` walked. Both look for a literal
  # file at `${IconThemePath}/${IconName}`. With only the conformant tree the
  # file isn't there -> Quickshell paints its `missingPixmap` (the magenta /
  # black checker pattern).
  #
  # Fix: put a symlink at exactly the path the naive join produces. Pointing
  # the symlink at the canonical `scalable/status/<mode>.svg` means QFile
  # opens the SVG transparently; QImageReader (auto-detect on by default)
  # then content-sniffs `<?xml…<svg…>` via the QtSvg plugin and renders.
  # Spec-conformant consumers (future Caelestia fix, other SNI hosts) keep
  # finding the icon under `scalable/status/`.
  modeIcons = pkgs.runCommand "power-mode-icons" { } ''
    base=$out/share/icons/PowerModes
    mkdir -p "$base/scalable/status"
    cat > "$base/index.theme" <<'EOF'
    [Icon Theme]
    Name=PowerModes
    Comment=Nixos-Diego five-mode power indicators
    Directories=scalable/status

    [scalable/status]
    Size=16
    MinSize=8
    MaxSize=512
    Type=Scalable
    Context=Status
    EOF
    cat > "$base/scalable/status/smart-sense.svg" <<'EOF'
    <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16" fill="currentColor">
      <path d="M8 1 L9 6 L14 7 L9 8 L8 13 L7 8 L2 7 L7 6 Z"/>
      <circle cx="13" cy="3" r="1"/>
      <circle cx="3" cy="13" r="1"/>
    </svg>
    EOF
    cat > "$base/scalable/status/performance.svg" <<'EOF'
    <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16" fill="currentColor">
      <path d="M8 1 L13 8 L10 8 L10 14 L6 14 L6 8 L3 8 Z"/>
    </svg>
    EOF
    cat > "$base/scalable/status/cool.svg" <<'EOF'
    <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" fill="none">
      <line x1="8" y1="1" x2="8" y2="15"/>
      <line x1="1" y1="8" x2="15" y2="8"/>
      <line x1="3" y1="3" x2="13" y2="13"/>
      <line x1="3" y1="13" x2="13" y2="3"/>
      <path d="M6 2 L8 4 L10 2 M6 14 L8 12 L10 14 M2 6 L4 8 L2 10 M14 6 L12 8 L14 10"/>
    </svg>
    EOF
    cat > "$base/scalable/status/quiet.svg" <<'EOF'
    <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">
      <path fill="currentColor" d="M2 6 H5 L9 3 V13 L5 10 H2 Z"/>
      <path stroke="currentColor" stroke-width="1.5" stroke-linecap="round" fill="none" d="M11 6 L15 10 M15 6 L11 10"/>
    </svg>
    EOF
    cat > "$base/scalable/status/power-saver.svg" <<'EOF'
    <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16" fill="currentColor">
      <path d="M2 14 C 2 8, 8 2, 14 2 C 14 8, 8 14, 2 14 Z"/>
      <path stroke="#000" stroke-opacity="0.4" stroke-width="0.8" fill="none" d="M2 14 L 14 2"/>
    </svg>
    EOF

    # Extensionless symlinks at the theme root — see header comment for why.
    # Relative target so the link stays valid under whatever /nix/store hash.
    for src in "$base"/scalable/status/*.svg; do
      name=$(basename "$src" .svg)
      ln -s "scalable/status/$name.svg" "$base/$name"
    done
  '';

  # Absolute path to the theme dir — passed via env var; the indicator hands
  # it to AppIndicator.set_icon_theme_path which propagates to SNI IconThemePath.
  modeIconThemePath = "${modeIcons}/share/icons/PowerModes";

  # Python tray indicator. Watches /var/lib/power-modes/current via inotify
  # (Gio.FileMonitor), updates icon on change, exposes 5-mode right-click menu.
  # Uses libayatana-appindicator3 — the de-facto SNI library; Caelestia's tray
  # (Quickshell SystemTray) consumes any StatusNotifierItem on the session bus.
  indicatorScript = pkgs.writeText "power-mode-indicator.py" ''
    import os
    import subprocess
    import gi
    gi.require_version("Gtk", "3.0")
    gi.require_version("AyatanaAppIndicator3", "0.1")
    from gi.repository import Gtk, AyatanaAppIndicator3 as AppIndicator, Gio

    STATE_FILE = "/var/lib/power-modes/current"
    ICON_THEME_PATH = os.environ["POWER_MODE_ICON_THEME_PATH"]

    MODES = [
        ("smart-sense", "Smart Sense"),
        ("performance", "Performance"),
        ("cool",        "Cool"),
        ("quiet",       "Quiet"),
        ("power-saver", "Power Saver"),
    ]
    LABELS = dict(MODES)
    FALLBACK = "smart-sense"

    def read_mode():
        try:
            with open(STATE_FILE) as f:
                m = f.read().strip()
            return m if m in LABELS else FALLBACK
        except OSError:
            return FALLBACK

    def set_mode(mode):
        subprocess.Popen(["power-mode", "set", mode])

    class Indicator:
        def __init__(self):
            # AppIndicator.Indicator.new() expects an icon *theme name* —
            # passing an absolute path here causes SNI registration with the
            # watcher to fail silently. set_icon_theme_path() registers our
            # bundled theme so set_icon_full(<mode>) can resolve via standard
            # XDG icon-theme lookup (Caelestia/Quickshell requires this — it
            # rejects absolute paths in IconName).
            self.ind = AppIndicator.Indicator.new_with_path(
                "power-modes-diego",
                "smart-sense",
                AppIndicator.IndicatorCategory.HARDWARE,
                ICON_THEME_PATH,
            )
            self.ind.set_status(AppIndicator.IndicatorStatus.ACTIVE)

            # Keep the menu + items as members; PyGObject GC otherwise frees
            # them after __init__ returns and the indicator silently falls off
            # the StatusNotifierWatcher.
            self.menu = Gtk.Menu()
            self.items = []
            for mode, label in MODES:
                item = Gtk.MenuItem(label=label)
                item.connect("activate", lambda _w, m=mode: set_mode(m))
                self.menu.append(item)
                self.items.append(item)
            self.menu.show_all()
            self.ind.set_menu(self.menu)

            gfile = Gio.File.new_for_path(STATE_FILE)
            self.monitor = gfile.monitor_file(Gio.FileMonitorFlags.NONE, None)
            self.monitor.connect("changed", lambda *_: self.update())

            self.update()

        def update(self):
            mode = read_mode()
            self.ind.set_icon_full(mode, LABELS[mode])
            self.ind.set_title(f"Power mode: {LABELS[mode]}")

    if __name__ == "__main__":
        # Bind to a name so PyGObject keeps the instance (and the contained
        # AppIndicator + menu + monitor) alive for the duration of Gtk.main().
        # Without this, Python's refcount drops to 0 immediately and the SNI
        # registration never reaches the watcher.
        indicator = Indicator()  # noqa: F841
        Gtk.main()
  '';

  # Launcher: PyGObject + GI typelib paths for AyatanaAppIndicator3 + GTK.
  # `pygobject3` brings the Python bindings; GI_TYPELIB_PATH must point at the
  # .typelib files of each library we import (Gtk, AppIndicator, Gio).
  powerModeIndicator = pkgs.writeShellApplication {
    name = "power-mode-indicator";
    runtimeInputs = [
      (pkgs.python3.withPackages (ps: [ ps.pygobject3 ]))
    ];
    runtimeEnv = {
      # glib and pango default to their `bin` output (no typelibs there);
      # other listed packages already default to the right output. Force `.out`
      # to grab the lib/girepository-1.0 with the actual .typelib files.
      GI_TYPELIB_PATH = lib.makeSearchPath "lib/girepository-1.0" [
        pkgs.gtk3
        pkgs.libayatana-appindicator
        pkgs.glib.out
        pkgs.gdk-pixbuf
        pkgs.pango.out
        pkgs.atk
        pkgs.harfbuzz
        # Provides xlib-2.0.typelib (GTK3 transitively imports xlib via Gdk).
        pkgs.gobject-introspection
      ];
      POWER_MODE_ICON_THEME_PATH = modeIconThemePath;
    };
    text = ''
      exec python3 ${indicatorScript}
    '';
  };

in
{
  options.services.powerModes = {
    enable = lib.mkEnableOption "five-mode declarative power management";

    defaultMode = lib.mkOption {
      type = lib.types.enum validModeNames;
      default = "smart-sense";
      description = ''
        Mode applied at boot if no state file exists or if the existing
        state is invalid.
      '';
    };

    profiles = lib.mkOption {
      description = ''
        Mode definitions. Each profile composes one ppd profile with a
        small set of overrides that ppd does not expose: EPP override,
        CPU boost, scaling_max_freq cap, GPU DPM. Override any default
        from the host file via
        `services.powerModes.profiles.<name>.<knob> = …`.
      '';

      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          ppdProfile = lib.mkOption {
            type = lib.types.enum [
              "power-saver"
              "balanced"
              "performance"
            ];
            description = ''
              Underlying power-profiles-daemon profile. Sets the firmware
              platform_profile (low-power / balanced / performance) via
              ppd's standard mapping.
            '';
          };
          eppOverride = lib.mkOption {
            type = lib.types.nullOr (lib.types.enum [
              "default"
              "performance"
              "balance_performance"
              "balance_power"
              "power"
            ]);
            default = null;
            description = ''
              EPP override written to every CPU policy. Null leaves
              ppd's default in place.
            '';
          };
          boost = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              CPU boost (amd_pstate cpb_boost). The single most
              measurable knob on Strix Halo per Phoronix benchmarks —
              ~1–3 W average savings, 5–10 % battery on burst loads
              when disabled.
            '';
          };
          scalingMaxPercent = lib.mkOption {
            type = lib.types.nullOr (lib.types.ints.between 10 100);
            default = null;
            description = ''
              Cap scaling_max_freq to this percentage of
              cpuinfo_max_freq. Null = no cap (firmware default).
              Cosmetic for sustained loads (thermal limits earlier),
              meaningful for burst-suppression battery modes.
            '';
          };
          gpuDpm = lib.mkOption {
            type = lib.types.enum [
              "auto"
              "low"
              "high"
              "manual"
            ];
            default = "auto";
            description = ''
              GPU power_dpm_force_performance_level. On RDNA 3.5
              "auto" is best — the iGPU drops idle p-states
              autonomously. "low" risks compositor stutter for
              marginal savings.
            '';
          };
        };
      });

      # Don-revised defaults. Mode → knob mapping rationale lives in the
      # ADR; in short: cpb_boost is the only real lever; scaling_max_freq
      # caps are cosmetic on Strix Halo except for burst-suppression in
      # power-saver; GPU DPM stays auto everywhere on RDNA 3.5; Smart Sense
      # applies no overrides (UX bookkeeping for Windows parity, identical
      # observable behavior to "do nothing on top of ppd-balanced").
      default = {
        smart-sense = {
          ppdProfile = "balanced";
          # Explicitly "default" rather than null: writes "default" to the EPP
          # node, which makes amd_pstate-epp apply the kernel's per-profile
          # default. Ensures Smart Sense actively *resets* EPP back to the
          # ppd-balanced default (balance_performance) even when coming from
          # another mode that had set balance_power or power.
          eppOverride = "default";
          boost = true;
        };
        performance = {
          ppdProfile = "performance";
          eppOverride = "performance";
          boost = true;
        };
        cool = {
          ppdProfile = "balanced";
          eppOverride = "balance_power";
          boost = true;
        };
        quiet = {
          ppdProfile = "power-saver";
          eppOverride = "balance_power";
          boost = false;
        };
        power-saver = {
          ppdProfile = "power-saver";
          eppOverride = "power";
          boost = false;
          scalingMaxPercent = 50;
        };
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.services.power-profiles-daemon.enable;
        message =
          "services.powerModes requires services.power-profiles-daemon.enable = true "
          + "(ppd is the bedrock the five modes layer on top of).";
      }
    ];

    # /etc/power-modes/<mode>.env — one file per profile. EnvironmentFile=
    # for the templated unit reads these. Empty values mean "no override".
    environment.etc = lib.mapAttrs' (
      name: profile:
      lib.nameValuePair "power-modes/${name}.env" {
        mode = "0644";
        text = ''
          MODE=${name}
          PPD_PROFILE=${profile.ppdProfile}
          EPP_OVERRIDE=${if profile.eppOverride == null then "" else profile.eppOverride}
          BOOST=${if profile.boost then "1" else "0"}
          SCALING_MAX_PCT=${if profile.scalingMaxPercent == null then "" else toString profile.scalingMaxPercent}
          GPU_DPM=${profile.gpuDpm}
        '';
      }
    ) cfg.profiles;

    environment.systemPackages = [ powerModeCli ];

    # State directory for /var/lib/power-modes/current.
    systemd.tmpfiles.rules = [
      "d /var/lib/power-modes 0775 root wheel - -"
    ];

    # Templated apply unit. Polkit allows wheel members to `systemctl start`
    # this without a password, scoped to the specific instance pattern below.
    systemd.services."power-modes-apply@" = {
      description = "Apply power mode %i";
      # No wantedBy / wants — only triggered on demand by the CLI or by
      # power-modes-restore.service.
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = "/etc/power-modes/%i.env";
        ExecStart = "${pkgs.bash}/bin/bash ${applyScript}";

        # Hardening — runs as root, so close the blast radius. Touches
        # only the sysfs paths we actually write, plus our state dir.
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        ProtectKernelLogs = true;
        ProtectClock = true;
        LockPersonality = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        ReadWritePaths = [
          "/sys/devices/system/cpu"
          "/sys/class/drm"
          "/sys/firmware/acpi/platform_profile"
          "/var/lib/power-modes"
        ];
      };
    };

    # Restore last mode on boot. After=ppd so powerprofilesctl works; the
    # ConditionPathExists avoids a noisy failure on first ever boot.
    systemd.services.power-modes-restore = {
      description = "Restore last selected power mode after boot";
      after = [
        "power-profiles-daemon.service"
        "multi-user.target"
      ];
      wants = [ "power-profiles-daemon.service" ];
      wantedBy = [ "multi-user.target" ];
      unitConfig.ConditionPathExists = "/var/lib/power-modes";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.bash}/bin/bash ${restoreScript}";
      };
    };

    # Polkit rule — exact prefix/suffix + mode-name regex + verb whitelist.
    # No globs (Polkit-JS has no wildcard match on action.lookup values).
    # See ADR-0024 for the longer explanation; smoke-tests live in the
    # plan's verification gates.
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id !== "org.freedesktop.systemd1.manage-units") return;
        if (!subject.isInGroup("wheel")) return;
        var unit = action.lookup("unit") || "";
        if (unit.indexOf("power-modes-apply@") !== 0) return;
        if (unit.lastIndexOf(".service") !== unit.length - 8) return;
        var mode = unit.slice("power-modes-apply@".length, -".service".length);
        if (!/^(smart-sense|performance|cool|quiet|power-saver)$/.test(mode)) return;
        var verb = action.lookup("verb") || "";
        if (verb !== "start") return;
        return polkit.Result.YES;
      });
    '';

    # SNI tray indicator — user-level service that exposes the current power
    # mode as a StatusNotifierItem on the session bus. Caelestia's tray slot
    # consumes any SNI publisher and renders it next to Discord/etc., so the
    # mode is visible at-a-glance and right-clickable for direct switching.
    #
    # Replaces the pre-UPower "rocket fallback" the Battery slot rendered when
    # Caelestia thought no laptop battery was present — that fallback was tied
    # to ppd profile (3 values), this is tied to the actual 5-mode state.
    home-manager.users."${username}" = {
      systemd.user.services.power-mode-indicator = {
        Unit = {
          Description = "Power Mode Tray Indicator (5-mode Diego)";
          After = [ "graphical-session.target" ];
          PartOf = [ "graphical-session.target" ];
        };
        Service = {
          Type = "exec";
          ExecStart = "${powerModeIndicator}/bin/power-mode-indicator";
          Restart = "on-failure";
          RestartSec = "5s";
        };
        Install = {
          WantedBy = [ "graphical-session.target" ];
        };
      };
    };
  };
}
