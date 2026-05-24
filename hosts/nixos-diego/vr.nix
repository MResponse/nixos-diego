{ config, lib, pkgs, ... }:

# SteamVR + Steam Link VR (Pico 4) on Jovian-NixOS — comprehensive stability
# and performance setup. Implements Plan-0007 (v4.1-CONVERGED).
#
# Documented in ADR-0027 (foundation) + ADR-0028 (Plan-0007 phases).
#
# Bundles (all in this single file for cohesion + easy rollback):
#  - Foundation (ADR-0027): CAP_SYS_NICE auf vrcompositor-launcher, Firewall
#    UDP 10400/10401 + TCP 27037 für Steam Link VR's vrlink-Driver.
#  - F1 (Plan-0007): diego-vr-helper.sh — single-wrapper für Pre-Launch
#    Stale-Cleanup + Qt-xcb-Export + Proton-NO-ESYNC + SteamVR-Settings-Merge.
#    Ersetzt den v1-Style separaten Qt-Patch-Service.
#  - F2: Power-Pin (systemd.path on IPC-File-Glob) + Orphan-Cleanup-Timer.
#  - F3: RT-Privileges via loginLimits @audio.
#  - F5: PipeWire low-latency quantum=256 für VR-Audio.
#  - F7: localconfig.vdf Backup-Timer + Restore-Tool (über systemd.user, no HM).
#  - F8 ist in modules/gaming.nix (RADV_PERFTEST cleanup).
#  - F9: vr.nix patcher-services laufen als User=marius mit flock.
#  - F13: vr-doctor diagnostic command in environment.systemPackages.
#  - F14: vr-uninstall-patches rollback command.

let
  user = "marius";
  steamDefault = "/home/${user}/.local/share/Steam/steamapps/common/SteamVR";
  vrcompositorLauncher = "${steamDefault}/bin/linux64/vrcompositor-launcher";
  vrstartupSh = "${steamDefault}/bin/vrstartup.sh";

  # The single helper that vrstartup.sh becomes a thin wrapper to.
  # Lives on Steam's install dir. Runs at host-PATH BEFORE sniper-entry.
  diegoVrHelperContent = pkgs.writeText "diego-vr-helper.sh" ''
    #!/bin/bash
    # diego-vr-helper.sh — managed by hosts/nixos-diego/vr.nix (Plan-0007).
    # Single source of truth for SteamVR pre-launch setup on Diego.

    # 1. Conditional stale-cleanup (Plan-0007 F1). Only sleep if pkill matched.
    if pkill -9 -f "vrserver|vrcompositor|vrmonitor|vrwebhelper" 2>/dev/null; then
      sleep 1
    fi

    # 2. SteamVR settings merge (Plan-0007 F4, fold into helper).
    #    Pre-launch-timed (NOT login-time, because SteamVR rewrites the file
    #    on shutdown with in-memory state).
    cfg=~/.local/share/Steam/config/steamvr.vrsettings
    if [ -f "$cfg" ] && command -v jq >/dev/null 2>&1; then
      ( flock -x -w 5 200 || exit 0
        jq '.steamvr.enableLinuxVulkanAsync = false
          | .steamvr.supersampleManualOverride = true
          | .steamvr.supersampleScale = 1.0
          | .steamvr.allowSupersampleFiltering = false
          | .steamvr.vsync_to_photons_increment = 3' \
          "$cfg" > "$cfg.diego.new" \
          && mv "$cfg.diego.new" "$cfg"
      ) 200>"$cfg.lock" 2>/dev/null || true
    fi

    # 3. Environment defaults for the SteamVR session and its children.
    export QT_QPA_PLATFORM=xcb           # vrmonitor crash workaround
    export PROTON_NO_ESYNC=1             # iscriptevaluator-hang workaround (Issue #1717)

    # 4. Hand off to the unchanged Valve script.
    exec "$(dirname "$0")/vrstartup.sh.orig" "$@"
  '';

  # System-level installer that wraps vrstartup.sh into helper-call.
  # Runs as User=marius via systemd-service (Plan-0007 F9 race-fix).
  # Plan-0008 v4: idempotency-gate + explicit chmod 0755 + .orig self-heal.
  diegoVrInstallHelper = pkgs.writeShellScript "diego-vr-install-helper" ''
    set -eu

    # (Plan-0007 Q24-fix) Resolve SteamVR install path glob-safely.
    steamvr_path=""
    for candidate_root in ~/.steam/steam ~/.local/share/Steam; do
      cand="$candidate_root/steamapps/common/SteamVR"
      [ -d "$cand" ] && steamvr_path="$cand" && break
    done
    if [ -z "$steamvr_path" ]; then
      vdf=~/.steam/steam/steamapps/libraryfolders.vdf
      if [ -f "$vdf" ]; then
        while read -r libpath; do
          [ -d "$libpath/steamapps/common/SteamVR" ] \
            && steamvr_path="$libpath/steamapps/common/SteamVR" && break
        done < <(${pkgs.gnugrep}/bin/grep -oE '"path"[[:space:]]+"[^"]+"' "$vdf" \
                 | ${pkgs.coreutils}/bin/cut -d'"' -f4)
      fi
    fi
    [ -n "$steamvr_path" ] || { echo "DIEGO-VR: no SteamVR install found, exit 0" >&2; exit 0; }

    script="$steamvr_path/bin/vrstartup.sh"
    orig="$steamvr_path/bin/vrstartup.sh.orig"
    helper="$steamvr_path/bin/diego-vr-helper.sh"

    [ -f "$script" ] || exit 0

    # Plan-0008 v4 B1: single source of truth for managed wrapper content.
    # Hat keinen trailing-newline in der Variable; printf '%s\n' schreibt EINEN newline;
    # $(cat …) strippt den beim Lesen wieder. → symmetrischer Vergleich (idempotency-check).
    managed_content="#!/bin/bash
    # DIEGO-VR-MANAGED — vr.nix wrapper. To uninstall: vr-uninstall-patches
    exec \"$helper\" \"\$@\""

    # Plan-0008 v4 B6: .orig self-heal (orig kann 0644 sein nach Plan-0007 Bug).
    if [ -f "$orig" ] && [ ! -x "$orig" ]; then
      ${pkgs.coreutils}/bin/chmod 0755 "$orig"
    fi

    # Plan-0008 v4 B2: idempotency-gate — exit BEFORE any write if everything's correct.
    # Prevents path-unit self-feedback loop.
    if [ -f "$script" ] && [ -x "$script" ] \
       && [ "$(${pkgs.coreutils}/bin/cat "$script" 2>/dev/null)" = "$managed_content" ] \
       && [ -f "$helper" ] && [ -x "$helper" ] \
       && ${pkgs.diffutils}/bin/cmp -s "$helper" ${diegoVrHelperContent}; then
      exit 0
    fi

    # (Plan-0007 Q21-fix) Strukturelle sanity-check, robust gegen SteamVR-Updates.
    sane=1
    ${pkgs.coreutils}/bin/head -1 "$script" \
      | ${pkgs.gnugrep}/bin/grep -qE '^#!.*bash' || sane=0
    ${pkgs.gnugrep}/bin/grep -qE "vrstartup-helper|vrenv|vrsetup|DIEGO-VR-MANAGED" \
      "$script" || sane=0
    lines=$(${pkgs.coreutils}/bin/wc -l < "$script")
    [ "$lines" -le 300 ] || sane=0
    if [ "$sane" = 0 ]; then
      echo "DIEGO-VR: vrstartup.sh failed structural sanity, skipping" >&2
      exit 0
    fi

    (
      ${pkgs.util-linux}/bin/flock -x -w 30 200 || exit 1
      sleep 0.05

      already_managed=0
      ${pkgs.gnugrep}/bin/grep -q "DIEGO-VR-MANAGED" "$script" && already_managed=1

      if [ "$already_managed" = 0 ]; then
        # First-time: derive a clean .orig.
        # Existing vr.nix (ADR-0027 v1) injected `# DIEGO-VR-PATCH-QT` + export line
        # after the shebang. Strip those lines before saving as .orig so the
        # helper's own QT export isn't a double-set.
        if ${pkgs.gnugrep}/bin/grep -q "DIEGO-VR-PATCH-QT" "$script"; then
          ${pkgs.gnused}/bin/sed -E '/DIEGO-VR-PATCH-QT/{N;d;}' "$script" > "$orig"
        else
          ${pkgs.coreutils}/bin/cp -p "$script" "$orig"
        fi
        # Plan-0008 v4 B1: orig must always be executable (sed-redirect strips +x).
        ${pkgs.coreutils}/bin/chmod 0755 "$orig"
      fi

      # Always (re)install helper — idempotent, picks up content updates.
      ${pkgs.coreutils}/bin/install -m 0755 ${diegoVrHelperContent} "$helper"

      # Plan-0008 v4 B1: explicit 0755, NOT chmod --reference (would inherit
      # bad mode from a corrupted .orig).
      ${pkgs.coreutils}/bin/printf '%s\n' "$managed_content" > "$script.new"
      ${pkgs.coreutils}/bin/chmod 0755 "$script.new"
      ${pkgs.coreutils}/bin/mv "$script.new" "$script"
    ) 200>"$script.lock"
  '';

  # Diagnostic aggregator (Plan-0007 F13, Plan-0008 v4 B7/B9 enrichment).
  vrDoctor = pkgs.writeShellApplication {
    name = "vr-doctor";
    runtimeInputs = with pkgs; [
      libcap systemd jq nftables procps coreutils gnugrep gnused
      mesa-demos vulkan-tools diffutils
    ];
    text = ''
      # Plan-0008 v4 B7: ANSI colors for warning/ok lines.
      RED=$'\033[1;31m'
      GREEN=$'\033[1;32m'
      NC=$'\033[0m'

      echo "=== vr-doctor — $(date) ==="

      echo "--- Cap on vrcompositor-launcher ---"
      getcap ~/.local/share/Steam/steamapps/common/SteamVR/bin/linux64/vrcompositor-launcher 2>&1 \
        || echo "  (file missing)"

      # Plan-0008 v4 B7: explicit exec-bit check on all three managed files.
      echo "--- exec-bit check (must all be -rwxr-xr-x) ---"
      for f in ~/.local/share/Steam/steamapps/common/SteamVR/bin/vrstartup.sh \
               ~/.local/share/Steam/steamapps/common/SteamVR/bin/vrstartup.sh.orig \
               ~/.local/share/Steam/steamapps/common/SteamVR/bin/diego-vr-helper.sh; do
        if [ ! -e "$f" ]; then
          printf "  %s!! %s missing%s\n" "$RED" "$f" "$NC"
          continue
        fi
        mode=$(stat -c '%A' "$f")
        case "$mode" in
          -rwx*) printf "  %sok%s  %s %s\n" "$GREEN" "$NC" "$mode" "$f" ;;
          *)     printf "  %s!!%s  %s %s %s(no +x)%s\n" "$RED" "$NC" "$mode" "$f" "$RED" "$NC" ;;
        esac
      done

      echo "--- vrstartup.sh state ---"
      head -3 ~/.local/share/Steam/steamapps/common/SteamVR/bin/vrstartup.sh 2>&1 || true
      if [ -f ~/.local/share/Steam/steamapps/common/SteamVR/bin/vrstartup.sh.orig ]; then
        echo "  .orig backup: OK"
      else
        echo "  .orig backup: MISSING"
      fi
      if [ -f ~/.local/share/Steam/steamapps/common/SteamVR/bin/diego-vr-helper.sh ]; then
        echo "  helper: OK"
      else
        echo "  helper: MISSING"
      fi

      # Plan-0008 v4 B7: loop-detection on both managed services.
      echo "--- helper-install + cap-service health (Plan-0008 loop-detect) ---"
      for u in steamvr-diego-helper-install steamvr-vrcompositor-cap; do
        starts=$(journalctl -u "$u" --since "10 minutes ago" 2>/dev/null \
                 | grep -c "Starting" || true)
        starts=''${starts:-0}
        if [ "$starts" -gt 8 ]; then
          printf "  %s!! %s: %s starts/10min — FEEDBACK LOOP suspected%s\n" "$RED" "$u" "$starts" "$NC"
          printf "     Recovery: sudo systemctl stop %s.path\n" "$u"
        else
          printf "  %sok%s %s: %s starts/10min\n" "$GREEN" "$NC" "$u" "$starts"
        fi
      done

      echo "--- systemd VR units ---"
      for u in steamvr-vrcompositor-cap.path steamvr-diego-helper-install.path \
               power-modes-vr-apply.path power-modes-vr-apply.service \
               power-modes-vr-orphan-cleanup.timer; do
        state=$(systemctl is-active "$u" 2>/dev/null || echo unknown)
        echo "  $u = $state"
      done

      # Plan-0008 v4 B9: graphics-stack info (Mesa version, RADV vs AMDVLK).
      echo "--- graphics stack ---"
      if [ -n "''${DISPLAY:-}" ] || [ -n "''${WAYLAND_DISPLAY:-}" ]; then
        glxinfo -B 2>/dev/null | grep -E "OpenGL renderer|OpenGL version" || true
      else
        echo "  (no DISPLAY — skip glxinfo; vulkaninfo below covers GPU detection)"
      fi
      vulkaninfo --summary 2>/dev/null \
        | grep -E "driverName|driverInfo|deviceName" | head -6 || true
      mesa_lib=$(realpath /run/opengl-driver/share/vulkan/icd.d/radeon_icd.x86_64.json 2>/dev/null || true)
      mesa_ver=$(echo "$mesa_lib" | grep -oE 'mesa-[0-9.]+' | head -1 || true)
      if [ -z "$mesa_ver" ]; then
        mesa_ver=$(cat /run/opengl-driver/share/vulkan/icd.d/radeon_icd.x86_64.json 2>/dev/null \
                   | grep -oE '"api_version"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 || true)
      fi
      echo "  Mesa: ''${mesa_ver:-(unknown)}"
      if vulkaninfo --summary 2>&1 | grep -qi "amdvlk"; then
        printf "  %s!! AMDVLK detected — known to break SteamVR. Use RADV only.%s\n" "$RED" "$NC"
      fi

      echo "--- Mode: STREAMING-ONLY (Pico via Steam-Link) ---"
      echo "  Kein physischer HMD am Diego → DRM-Lease nicht relevant"
      echo "  → Pico-Side: Pico-Connect-App ≥ 10.4.5, NICHT Streaming Assistant"

      # Plan-0009 S7: Wi-Fi band check (5 GHz strongly recommended for VR).
      echo "--- Wi-Fi band check ---"
      wifi_freq=$(${pkgs.networkmanager}/bin/nmcli -t -f IN-USE,FREQ dev wifi 2>/dev/null \
                  | ${pkgs.gnugrep}/bin/grep '^\*' | ${pkgs.coreutils}/bin/cut -d: -f2)
      if echo "$wifi_freq" | ${pkgs.gnugrep}/bin/grep -qE "^5[0-9]{3} MHz"; then
        printf "  %sok%s Wi-Fi on 5 GHz (%s)\n" "$GREEN" "$NC" "$wifi_freq"
      else
        printf "  %s!! Wi-Fi on %s — switch to 5 GHz for VR streaming%s\n" "$RED" "$wifi_freq" "$NC"
        printf "     Recovery: sudo nmcli connection modify <SSID> 802-11-wireless.band a\n"
      fi

      # Plan-0009 S2: OpenXR runtime registration check.
      echo "--- OpenXR runtime registration ---"
      if [ -L ~/.config/openxr/1/active_runtime.json ] \
         || [ -f ~/.config/openxr/1/active_runtime.json ]; then
        target=$(${pkgs.coreutils}/bin/readlink -f ~/.config/openxr/1/active_runtime.json 2>/dev/null \
                 || echo "(file, not symlink)")
        printf "  %sok%s OpenXR runtime → %s\n" "$GREEN" "$NC" "$target"
      else
        printf "  %s!! ~/.config/openxr/1/active_runtime.json missing — OpenXR games fall to flat-mode%s\n" "$RED" "$NC"
      fi

      # Plan-0009 S6: WiVRn alternative-stack status.
      echo "--- WiVRn alternative-stack (optional) ---"
      if ${pkgs.systemd}/bin/systemctl --user is-active wivrn-server.service 2>/dev/null \
         | ${pkgs.gnugrep}/bin/grep -q "^active"; then
        echo "  WiVRn-server: active (using Monado, not SteamVR)"
      else
        echo "  WiVRn-server: inactive (SteamVR is primary)"
      fi

      echo "--- Optional VR tools ---"
      command -v wayvr        >/dev/null && echo "  wayvr: OK (in-VR Wayland overlay)" || echo "  wayvr: missing"
      # xrizer ships only a .so library (vrclient.so), no CLI; detect via store-path.
      if ${pkgs.coreutils}/bin/ls -d /nix/store/*-xrizer-* 2>/dev/null | ${pkgs.coreutils}/bin/head -1 >/dev/null; then
        echo "  xrizer: OK (OpenVR→OpenXR shim — library, used by Steam games)"
      else
        echo "  xrizer: missing"
      fi
      command -v mangohud      >/dev/null && echo "  mangohud: OK (FLAT-only; do NOT set MANGOHUD=1 globally in VR)" || echo "  mangohud: missing"

      echo "--- Steam-Link bitrate reminder ---"
      echo "  Manual cap: Steam Settings → Remote Play → Advanced Host → HEVC + 150 Mbps CBR"

      echo "--- amdgpu power-pin ---"
      command -v power-mode >/dev/null && power-mode get 2>&1 || true
      for f in /sys/class/drm/card*/device/power_dpm_force_performance_level; do
        [ -e "$f" ] && echo "  $f = $(cat "$f")"
      done

      echo "--- RT-limits (this shell) ---"
      echo "  rtprio = $(ulimit -r)"
      echo "  memlock = $(ulimit -l)"

      echo "--- SteamVR settings ---"
      if [ -f ~/.local/share/Steam/config/steamvr.vrsettings ]; then
        jq '.steamvr | {enableLinuxVulkanAsync,supersampleScale,vsync_to_photons_increment}' \
          ~/.local/share/Steam/config/steamvr.vrsettings 2>/dev/null \
          || echo "  (parse failed)"
      else
        echo "  (file missing)"
      fi

      echo "--- RADV / Mesa ---"
      echo "  RADV_PERFTEST=''${RADV_PERFTEST:-(unset)}"

      echo "--- Firewall VR ports (root-needed; best-effort) ---"
      nft list ruleset 2>/dev/null | grep -E "10400|10401|27037" \
        || echo "  (run as root to see firewall state)"

      echo "--- live VR processes ---"
      pgrep -af "vrserver|vrcompositor|vrmonitor|vrwebhelper|vrstartup" 2>/dev/null \
        | grep -v vr-doctor | head -5 || echo "  none"

      echo "--- network / VPN ---"
      if command -v tailscale >/dev/null 2>&1; then
        tailscale status 2>/dev/null | head -2 || echo "  tailscale inactive"
      else
        echo "  tailscale not installed"
      fi

      echo "--- vrserver last shutdown reason ---"
      grep -E "Waiting for connection|Shutting down|Connection inactive" \
        ~/.local/share/Steam/logs/vrserver.txt 2>/dev/null | tail -3 || true

      echo "--- recent journal (last hour) ---"
      journalctl --no-pager --since "1 hour ago" \
        -u steamvr-vrcompositor-cap.service \
        -u steamvr-diego-helper-install.service \
        -u power-modes-vr-apply.service 2>/dev/null \
        | tail -15 || true

      echo "=== END ==="
    '';
  };

  # Rollback tool (Plan-0007 F14, Plan-0008 v4 B1 chmod-explicit).
  vrUninstallPatches = pkgs.writeShellApplication {
    name = "vr-uninstall-patches";
    runtimeInputs = with pkgs; [ coreutils ];
    text = ''
      set -eu
      dir=~/.local/share/Steam/steamapps/common/SteamVR/bin
      if [ ! -d "$dir" ]; then
        echo "No SteamVR install at $dir, nothing to do."
        exit 0
      fi
      cd "$dir"
      if [ -f vrstartup.sh.orig ]; then
        install -m 0755 vrstartup.sh.orig vrstartup.sh
        rm -f vrstartup.sh.orig
        echo "vrstartup.sh restored from .orig backup (chmod 0755)."
      else
        echo "No .orig backup found; current vrstartup.sh kept as-is."
      fi
      rm -f diego-vr-helper.sh
      echo "Helper removed."
      echo
      echo "To fully roll back: edit hosts/nixos-diego/vr.nix to remove path"
      echo "watchers and run: sudo nixos-rebuild switch"
    '';
  };

  # Backup helper (Plan-0007 F7) — invoked by systemd.user.timer.
  steamLocalconfigBackupScript = pkgs.writeShellScript "steam-localconfig-backup" ''
    set -eu
    backup_root=~/.local/share/steam-localconfig-backups
    ${pkgs.coreutils}/bin/mkdir -p "$backup_root"
    ts=$(${pkgs.coreutils}/bin/date +%Y%m%d-%H%M%S)
    for cfg in ~/.local/share/Steam/userdata/*/config/localconfig.vdf; do
      [ -f "$cfg" ] || continue
      uid=$(${pkgs.coreutils}/bin/basename "$(dirname "$(dirname "$cfg")")")
      ${pkgs.util-linux}/bin/flock -s -w 5 "$cfg" -c \
        "${pkgs.coreutils}/bin/cp -p '$cfg' '$backup_root/localconfig-$uid-$ts.vdf'" \
        2>/dev/null || true
    done
    # Rotate: keep latest 20 (matches Plan-0007 §9).
    ${pkgs.findutils}/bin/find "$backup_root" -maxdepth 1 -name 'localconfig-*.vdf' \
      | ${pkgs.coreutils}/bin/sort -r \
      | ${pkgs.coreutils}/bin/tail -n +21 \
      | ${pkgs.findutils}/bin/xargs -r ${pkgs.coreutils}/bin/rm -f
  '';

  # Restore tool (companion to F7).
  vrRestoreConfig = pkgs.writeShellApplication {
    name = "vr-restore-config";
    runtimeInputs = with pkgs; [ coreutils findutils ];
    text = ''
      backup_root=~/.local/share/steam-localconfig-backups
      if [ ! -d "$backup_root" ]; then
        echo "No backup directory at $backup_root; nothing to restore."
        exit 1
      fi
      latest=$(find "$backup_root" -maxdepth 1 -name 'localconfig-*.vdf' \
        | sort -r | head -1)
      if [ -z "$latest" ]; then
        echo "No backups present in $backup_root."
        exit 1
      fi
      # Extract uid from filename: localconfig-<uid>-<ts>.vdf
      base=$(basename "$latest")
      uid=$(echo "$base" | sed -E 's/^localconfig-([^-]+)-.*$/\1/')
      target=~/.local/share/Steam/userdata/$uid/config/localconfig.vdf
      if [ ! -d "$(dirname "$target")" ]; then
        echo "No matching userdata dir for uid=$uid ($target)"
        exit 1
      fi
      # Save current as crash-loop backup
      if [ -f "$target" ]; then
        cp -p "$target" "$target.before-restore.$(date +%Y%m%d-%H%M%S)"
      fi
      cp -p "$latest" "$target"
      echo "Restored $latest to $target"
      echo "Old file backed up beside it (.before-restore.*)."
    '';
  };

in
{
  ##############################################################
  # Foundation (ADR-0027): CAP_SYS_NICE + Firewall              #
  ##############################################################

  systemd.services.steamvr-vrcompositor-cap = {
    description = "Apply CAP_SYS_NICE to SteamVR vrcompositor-launcher";
    # Plan-0008 v4 B4: Defense-in-Depth — limit cascading triggers.
    startLimitIntervalSec = 60;
    startLimitBurst = 15;
    # Plan-0008 v5: run at boot since we dropped PathExists from the .path.
    # The condition-block in ExecStart (getcap-gate) ensures idempotency
    # even if the file isn't ready yet.
    wantedBy = [ "graphical.target" ];
    serviceConfig = {
      Type = "oneshot";
      # Needs root for setcap CAP_SETFCAP — stays as root (Q5-fix split).
      User = "root";
      # Plan-0008 v4 B3: idempotency-gate inline — only setcap if not already present.
      # Prevents path-unit self-feedback from xattr-change re-triggering.
      ExecStart = pkgs.writeShellScript "steamvr-vrcompositor-setcap" ''
        if ${pkgs.libcap}/bin/getcap ${vrcompositorLauncher} 2>/dev/null \
           | ${pkgs.gnugrep}/bin/grep -q "cap_sys_nice=eip"; then
          exit 0
        fi
        exec ${pkgs.libcap}/bin/setcap CAP_SYS_NICE=eip ${vrcompositorLauncher}
      '';
      SuccessExitStatus = [ 0 1 ];
    };
  };

  systemd.paths.steamvr-vrcompositor-cap = {
    description = "Watch SteamVR vrcompositor-launcher for changes";
    wantedBy = [ "multi-user.target" ];
    # Plan-0008 v5: PathExists DROPPED — it re-fires from WAITING state because
    # the file always exists, creating a tight loop with the service that
    # itself does no fs-modification. Use only PathChanged (fires only on
    # actual modify events). Service runs at boot via wantedBy on the SERVICE.
    pathConfig = {
      PathChanged = vrcompositorLauncher;
      Unit = "steamvr-vrcompositor-cap.service";
    };
  };

  networking.firewall = {
    allowedUDPPorts = [ 10400 10401 ];
    allowedTCPPorts = [ 27037 ];
  };

  ##############################################################
  # Plan-0009 — OpenXR + monitoring + alternative-stack         #
  ##############################################################

  # Plan-0009 S2: Pressure-Vessel needs to import host's OpenXR runtime
  # registration so Wine/Proton-launched OpenXR games (Beat Saber, Unity-VR)
  # can find SteamVR's OpenXR. Without this, games silently fall back to
  # flat-mode (visible only on the laptop display, not in the HMD).
  # Set globally because programs.steam has no top-level extraEnv attribute
  # in this NixOS version; Steam inherits env-vars from the launching shell.
  environment.sessionVariables = {
    PRESSURE_VESSEL_IMPORT_OPENXR_1_RUNTIMES = "1";
  };

  # Plan-0009 S6: WiVRn as optional alternative-stack (Monado-based, native
  # Linux VR streaming with AV1 via VAAPI on Strix Halo VCN 4). On-demand:
  # user must `systemctl --user start wivrn-server.service` to use it.
  # SteamVR remains the primary stack (Plan-0007 + Plan-0008).
  services.wivrn = {
    enable = true;
    openFirewall = true;
    autoStart = false;        # never auto-start; only when user explicitly runs WiVRn
    highPriority = true;      # CAP_SYS_NICE for Monado async-reprojection
  };

  ##############################################################
  # F1 (helper-wrapper)                                         #
  ##############################################################

  systemd.services.steamvr-diego-helper-install = {
    description = "Install diego-vr-helper wrapper around SteamVR's vrstartup.sh";
    # Plan-0008 v4 B4: Defense-in-Depth — limit cascading triggers (idempotency in B2).
    startLimitIntervalSec = 60;
    startLimitBurst = 15;
    # Plan-0008 v4 B11: re-run service on nix-store-hash change (helper-content updates
    # at rebuild without vrstartup.sh changing on disk).
    restartTriggers = [ diegoVrHelperContent ];
    # Plan-0008 v5: run at boot since we dropped PathExists from the .path.
    # The install-helper script handles "no SteamVR yet" gracefully (exit 0).
    wantedBy = [ "graphical.target" ];
    serviceConfig = {
      Type = "oneshot";
      User = user;          # (Q5-fix) writes its own files
      Group = "users";
      ExecStart = "${diegoVrInstallHelper}";
      SuccessExitStatus = [ 0 1 ];
    };
  };

  systemd.paths.steamvr-diego-helper-install = {
    description = "Watch SteamVR vrstartup.sh for changes (re-install helper)";
    wantedBy = [ "multi-user.target" ];
    # Plan-0008 v5: same fix as cap-path — drop PathExists (loops forever
    # because file always exists). Service runs at boot via wantedBy on the
    # SERVICE itself; rebuild-time updates via restartTriggers.
    pathConfig = {
      PathChanged = vrstartupSh;
      Unit = "steamvr-diego-helper-install.service";
    };
  };

  ##############################################################
  # F2 (power-pin + orphan cleanup)                             #
  ##############################################################

  # Marker dir for power-mode restore (analog gamescope-power.nix pattern,
  # but system-level path because path-unit triggers system service).
  systemd.tmpfiles.rules = [
    "d /var/lib/diego-vr 0755 root root -"
  ];

  systemd.services."power-modes-vr-apply" = {
    description = "Pin power-mode=performance + amdgpu high while SteamVR runs";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;

      # Capture previous mode BEFORE switching (race-defended: don't
      # overwrite an existing marker — that would corrupt restore).
      ExecStartPre = pkgs.writeShellScript "vr-capture-prev-mode" ''
        marker=/var/lib/diego-vr/prev-mode
        if [ -e "$marker" ]; then
          exit 0
        fi
        prev=$(${pkgs.coreutils}/bin/cat /var/lib/power-modes/current 2>/dev/null || echo smart-sense)
        case "$prev" in
          smart-sense|performance|cool|quiet|power-saver) ;;
          *) prev=smart-sense ;;
        esac
        ${pkgs.coreutils}/bin/printf '%s\n' "$prev" > "$marker"
      '';

      ExecStart = pkgs.writeShellScript "vr-apply-perf" ''
        ${pkgs.systemd}/bin/systemctl start power-modes-apply@performance.service || true
        for card in /sys/class/drm/card*/device; do
          if [ -e "$card/power_dpm_force_performance_level" ]; then
            echo high > "$card/power_dpm_force_performance_level" 2>/dev/null || true
          fi
        done
      '';

      ExecStop = pkgs.writeShellScript "vr-restore-perf" ''
        for card in /sys/class/drm/card*/device; do
          if [ -e "$card/power_dpm_force_performance_level" ]; then
            echo auto > "$card/power_dpm_force_performance_level" 2>/dev/null || true
          fi
        done
        marker=/var/lib/diego-vr/prev-mode
        prev=smart-sense
        if [ -r "$marker" ]; then
          prev=$(${pkgs.coreutils}/bin/cat "$marker")
          ${pkgs.coreutils}/bin/rm -f "$marker"
        fi
        case "$prev" in
          smart-sense|performance|cool|quiet|power-saver) ;;
          *) prev=smart-sense ;;
        esac
        ${pkgs.systemd}/bin/systemctl start "power-modes-apply@$prev.service" || true
      '';
    };
  };

  systemd.paths."power-modes-vr-apply" = {
    description = "Trigger VR power-pin while SteamVR IPC file exists";
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathExistsGlob = "/tmp/SteamVR-IPCControlFile-*";
      Unit = "power-modes-vr-apply.service";
    };
  };

  systemd.services."power-modes-vr-orphan-cleanup" = {
    description = "Reap stale SteamVR IPC files and trigger power-mode restore";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "vr-orphan-cleanup" ''
        any_live=0
        for f in /tmp/SteamVR-IPCControlFile-*; do
          [ -e "$f" ] || continue
          pid="''${f##*-}"
          if [ -d "/proc/$pid" ]; then
            any_live=1
          else
            ${pkgs.coreutils}/bin/rm -f "$f" 2>/dev/null || true
          fi
        done
        if [ "$any_live" = 0 ]; then
          if ${pkgs.systemd}/bin/systemctl is-active power-modes-vr-apply.service >/dev/null 2>&1; then
            ${pkgs.systemd}/bin/systemctl stop power-modes-vr-apply.service || true
          fi
        fi
      '';
    };
  };

  systemd.timers."power-modes-vr-orphan-cleanup" = {
    description = "Periodically reap stale SteamVR IPC orphans";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1m";
      OnUnitInactiveSec = "10s";
      Unit = "power-modes-vr-orphan-cleanup.service";
    };
  };

  ##############################################################
  # F3 (RT-Privileges)                                          #
  ##############################################################

  security.pam.loginLimits = [
    { domain = "@audio"; item = "memlock"; type = "-";    value = "unlimited"; }
    { domain = "@audio"; item = "rtprio";  type = "-";    value = "99"; }
    { domain = "@audio"; item = "nofile";  type = "soft"; value = "99999"; }
    { domain = "@audio"; item = "nofile";  type = "hard"; value = "99999"; }
  ];

  ##############################################################
  # F5 (PipeWire low-latency)                                   #
  ##############################################################

  services.pipewire.extraConfig.pipewire."99-vr-low-latency" = {
    "context.properties" = {
      "default.clock.min-quantum" = 256;
      "default.clock.quantum" = 256;
      "default.clock.max-quantum" = 1024;
    };
  };

  ##############################################################
  # F7 (localconfig.vdf Backup-Timer als systemd.user-unit)    #
  ##############################################################

  systemd.user.services.steam-localconfig-backup = {
    description = "Periodic backup of Steam localconfig.vdf";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${steamLocalconfigBackupScript}";
    };
  };

  systemd.user.timers.steam-localconfig-backup = {
    description = "Rotate Steam localconfig.vdf snapshots every 10 minutes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2m";
      OnUnitActiveSec = "10m";
      Unit = "steam-localconfig-backup.service";
    };
  };

  ##############################################################
  # F13 + F14 + restore-tool + jq dependency                   #
  ##############################################################

  # jq must be on host-PATH so diego-vr-helper.sh can use it for the
  # settings-merge (runs BEFORE sniper-runtime entry).
  environment.systemPackages = [
    pkgs.jq
    vrDoctor
    vrUninstallPatches
    vrRestoreConfig
    # Plan-0009 S5+S6: optional VR tools.
    #   wayvr        — Wayland-aware OpenVR overlay (formerly wlx-overlay-s)
    #   mangohud      — perf-overlay (avoid in VR; per-game opt-in only)
    #   xrizer        — modern OpenVR→OpenXR shim (replaces OpenComposite)
    pkgs.wayvr
    pkgs.mangohud
    pkgs.xrizer
  ];
}
