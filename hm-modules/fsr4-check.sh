# fsr4-check — confirm in-game FSR 4 (proton-cachyos RDNA 3.5 DLL-upgrade) is
# actually engaged for a game. Body for writeShellApplication (shebang +
# bash options are injected by Nix). See ADR-0038.
#
# Usage: fsr4-check [APPID] [EXE_BASENAME]
#   defaults: APPID=1297900 (Gothic 1 Remake), EXE=G1R-Win64-Shipping.exe
#
# [1]+[2] are STATIC (the DLL stays staged; the log is append-only) — they
# prove FSR 4 was SET UP, possibly on a PAST desktop launch. Only [3] (live
# process env) proves it is ENGAGED right now, and that needs a terminal
# alongside the running game (a desktop-session launch — Gaming Mode has no
# terminal). The in-game menu still shows "FSR 3.1" even when FSR 4 is live —
# verify here, not in the menu.

appid="${1:-1297900}"
exe="${2:-G1R-Win64-Shipping.exe}"
steam="$HOME/.steam/root"
pfxlog="$HOME/.cache/protonfixes/protonfixes.log"
cache_dir="$HOME/.cache/protonfixes/upscalers"

green=$'\e[32m'
red=$'\e[31m'
dim=$'\e[2m'
rst=$'\e[0m'
ok()   { printf '  %s✓%s %s\n' "$green" "$rst" "$1"; }
no()   { printf '  %s✗%s %s\n' "$red"   "$rst" "$1"; }
info() { printf '  %s•%s %s\n' "$dim"   "$rst" "$1"; }

# Locate the prefix across the main library + any extra library folders.
libs=("$steam/steamapps")
if [ -f "$steam/steamapps/libraryfolders.vdf" ]; then
  while IFS= read -r p; do
    libs+=("$p/steamapps")
  done < <(grep -oE '"/[^"]+"' "$steam/steamapps/libraryfolders.vdf" | tr -d '"')
fi
pfx=""
for base in "${libs[@]}"; do
  if [ -d "$base/compatdata/$appid" ]; then
    pfx="$base/compatdata/$appid"
    break
  fi
done

printf '%sFSR 4 check — AppID %s (%s)%s\n\n' "$dim" "$appid" "$exe" "$rst"

# [1] FSR4 DLL physically staged in the prefix, hash-matching the cached upgrade.
# STATIC: survives across launches (incl. a past desktop run) — proves "set up".
printf '[1] FSR4 DLL staged in the prefix (static — survives prior launches)\n'
cached="$(find "$cache_dir" -maxdepth 1 -name 'amdxcffx64*.dll' 2>/dev/null | head -1 || true)"
if [ -z "$pfx" ]; then
  no "no prefix found for AppID $appid (game never launched? pass the right APPID)"
else
  dll="$pfx/pfx/drive_c/windows/system32/amdxcffx64.dll"
  if [ -f "$dll" ] && [ -n "$cached" ]; then
    h1="$(sha256sum "$dll"    | cut -d' ' -f1)"
    h2="$(sha256sum "$cached" | cut -d' ' -f1)"
    if [ "$h1" = "$h2" ]; then
      ok "amdxcffx64.dll matches the cached FSR4 DLL ($h1)"
    else
      no "prefix DLL hash != cached FSR4 DLL ($h1 vs $h2) — stale/partial swap"
    fi
  else
    no "amdxcffx64.dll missing in prefix or cache — launch once with the upgrade"
  fi
  if [ -f "$pfx/fsr4_version" ]; then
    info "fsr4_version: $(<"$pfx/fsr4_version")"
  fi
fi
printf '\n'

# [2] protonfixes engaged the upgrade on the most recent launch (append-only
# log, so this reflects the LATEST launch — which may have been a desktop run).
printf '[2] protonfixes upgrade signal — most recent launch (may be desktop)\n'
line="$(grep -a 'Automatic FSR4 upgrade enabled' "$pfxlog" 2>/dev/null | tail -1 || true)"
if [ -n "$line" ]; then
  ok "$line"
else
  no "no 'Automatic FSR4 upgrade enabled' in protonfixes.log"
  info "launch option must export the var: PROTON_FSR4_RDNA3_UPGRADE=1 %command%"
fi
printf '\n'

# [3] Live game-process env — the ONLY check that proves FSR 4 is engaged
# RIGHT NOW. Scan ALL processes whose cmdline contains the exe (fixed-string,
# no regex). Why scan all and not just one pid: PROTON_FSR4_RDNA3_UPGRADE is
# inherited by the whole Steam reaper -> proton -> wine chain, but protonfixes
# injects DXIL_SPIRV_CONFIG=wmma_rdna3_workaround ONLY into the wine process
# (via subprocess env), so picking the lowest pid (the reaper) would
# false-negative the FP8 workaround. Pass each sub-check if ANY pid carries it.
printf '[3] live game-process env — proves FSR4 ENGAGED now (desktop session only)\n'
found_up=""
found_dxil=""
for pdir in /proc/[0-9]*; do
  [ -r "$pdir/cmdline" ] || continue
  if tr '\0' ' ' < "$pdir/cmdline" 2>/dev/null | grep -qF "$exe"; then
    [ -r "$pdir/environ" ] || continue
    e="$(tr '\0' '\n' < "$pdir/environ" 2>/dev/null || true)"
    if printf '%s\n' "$e" | grep -q '^PROTON_FSR4_RDNA3_UPGRADE=1$'; then
      found_up="${pdir##*/}"
    fi
    if printf '%s\n' "$e" | grep -q 'DXIL_SPIRV_CONFIG=.*wmma_rdna3_workaround'; then
      found_dxil="${pdir##*/}"
    fi
  fi
done
if [ -n "$found_up" ] || [ -n "$found_dxil" ]; then
  if [ -n "$found_up" ]; then
    ok "PROTON_FSR4_RDNA3_UPGRADE=1 (pid $found_up)"
  else
    no "PROTON_FSR4_RDNA3_UPGRADE=1 not in any game process (the missing-%command% gotcha)"
  fi
  if [ -n "$found_dxil" ]; then
    ok "DXIL_SPIRV_CONFIG=wmma_rdna3_workaround (pid $found_dxil) — RDNA 3.5 FP8 path live"
  else
    no "DXIL_SPIRV_CONFIG workaround not set in any game process — FSR4-on-RDNA3 not active"
  fi
else
  info "game not running — start it in a DESKTOP session (terminal coexists), then re-run"
fi
printf '\n'

# [4] Mesa FP8-emulation floor (needs >= 25.2).
printf '[4] Mesa FP8-emulation floor (need >= 25.2)\n'
icd="/run/opengl-driver/share/vulkan/icd.d/radeon_icd.x86_64.json"
mesa="$(readlink -f "$(grep -oE '/nix/store/[^"]+libvulkan_radeon.so' "$icd" 2>/dev/null | head -1)" 2>/dev/null | grep -oE 'mesa-[0-9.]+' || true)"
if [ -n "$mesa" ]; then
  ver="${mesa#mesa-}"
  if [ "$(printf '%s\n25.2\n' "$ver" | sort -V | head -1)" = "25.2" ]; then
    ok "$mesa (>= 25.2)"
  else
    no "$mesa (< 25.2 — below the FP8 floor; FSR4-on-RDNA3 cannot work)"
  fi
else
  info "could not read Mesa version from $icd"
fi
printf '\n'

printf '%s[1]+[2] show FSR 4 was SET UP (static; may be from a past desktop run).\n[3] shows it is ENGAGED right now. The in-game menu still says "FSR 3.1"\neven when FSR 4 is live — verify here, not in the menu.%s\n' "$dim" "$rst"
