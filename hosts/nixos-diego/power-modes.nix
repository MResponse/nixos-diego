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

      usage() {
        cat <<'EOF'
      power-mode — switch Diego's power mode

      Usage:
        power-mode list            list modes, current starred
        power-mode get             print current mode
        power-mode set <mode>      apply <mode>
        power-mode show            dump live sysfs values

      Modes: smart-sense | performance | cool | quiet | power-saver
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
        notify-send -u low -i battery-symbolic "Power mode: $pretty" "Now active" || true
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
  };
}
