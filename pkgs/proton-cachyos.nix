# ADR-0038 — CachyOS Proton as a declarative Steam compatibility tool.
#
# WHY a local package instead of a flake input:
#   The obvious candidate, github:kimjongbing/nix-proton-cachyos, is DEAD:
#   its `main` (and `update-proton-cachyos`) branches last moved 2025-02-05
#   and still pin proton-cachyos 9.0-20250126 — 16 months stale and from
#   *before* the mature FSR4-on-RDNA3 path existed. Its source URL also
#   points at the CachyOS pacman mirror (x86_64_v3 .pkg.tar.zst), which
#   rotates old packages out, so that pin would likely 404 today anyway.
#
#   The package is trivial (it's a Steam Linux Runtime build — see below),
#   so we vendor it against the upstream CachyOS GitHub *release* tarball,
#   which is versioned and immutable. Mirrors the in-tree `proton-ge-bin`
#   pattern exactly.
#
# WHY no autoPatchelf:
#   The `-slr` asset is the "Steam Linux Runtime" build. Steam runs it
#   INSIDE the pressure-vessel/sniper container, which provides its own
#   FHS + libraries. The host (NixOS) loader never touches these binaries,
#   so they need no patching — identical reasoning to nixpkgs proton-ge-bin,
#   which also just symlinks the unpacked tree into a `steamcompattool`
#   output. The `out` output is a deliberate breadcrumb so this can't be
#   added to environment.systemPackages by mistake.
#
# WHY x86_64_v3:
#   CachyOS publishes generic-x86_64, x86_64_v3 (AVX2-era) and arm64 assets.
#   The ZBook's Ryzen AI Max+ PRO 395 is Zen 5 (x86-64-v4 capable), so v3 is
#   safe and is the canonical "CachyOS-optimized" build. If a future asset
#   ever tripped an illegal-instruction fault, fall back to the plain
#   `-x86_64` asset (drop the `_v3`).
#
# FSR4 usage (the whole point):
#   Per game, set the Steam launch option:
#       PROTON_FSR4_RDNA3_UPGRADE=1 %command%
#   The Radeon 8060S is gfx1151 / RDNA 3.5, a gfx11-family part with no
#   native FP8 WMMA, so it uses the RDNA3 path: this var downloads the
#   RDNA3-optimized amdxcffx64.dll (v4.0.0 by default) into
#   ~/.cache/protonfixes/upscalers/ and auto-sets
#   DXIL_SPIRV_CONFIG="wmma_rdna3_workaround" (FP8 emulation over gfx11
#   WMMA). Needs Mesa >= 25.2 (we ship 26.1.2). The game must already
#   support FSR 3.1 — the swap upgrades FSR 3.1 -> FSR 4. A specific DLL
#   can be requested with e.g. PROTON_FSR4_RDNA3_UPGRADE=4.0.2.
#
# UPDATE / watch-mechanism (hand-pinned, no auto-updater):
#   Latest release: https://github.com/CachyOS/proton-cachyos/releases
#   Bump `version` to the newest non-prerelease `cachyos-<ver>` tag (drop
#   the `cachyos-` prefix here), then refresh `hash` via the fake-hash
#   build trick:
#       nix build .#nixosConfigurations.nixos-diego.pkgs.proton-cachyos \
#         2>&1 | grep -A2 'specified:'
#   Releases cadence is roughly weekly.
{
  lib,
  stdenvNoCC,
  fetchzip,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "proton-cachyos";
  # Release tag is `cachyos-${version}`; asset is
  # `proton-cachyos-${version}-x86_64_v3.tar.xz`.
  version = "11.0-20260601-slr";

  src = fetchzip {
    url = "https://github.com/CachyOS/proton-cachyos/releases/download/cachyos-${finalAttrs.version}/proton-cachyos-${finalAttrs.version}-x86_64_v3.tar.xz";
    hash = "sha256-LOJX4H3g3+9yTQ78RUOJ05p/SLJFJCyyRQ6G/rThyDU=";
  };

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  outputs = [
    "out"
    "steamcompattool"
  ];

  installPhase = ''
    runHook preInstall

    # Refuse environment installation — this is for
    # programs.steam.extraCompatPackages only.
    echo "${finalAttrs.pname} should not be installed into environments. Please use programs.steam.extraCompatPackages instead." > $out

    mkdir $steamcompattool
    ln -s $src/* $steamcompattool

    # Replace the symlinked manifest with a writable copy so preFixup can set
    # a friendly Steam display name.
    rm $steamcompattool/compatibilitytool.vdf
    cp $src/compatibilitytool.vdf $steamcompattool/
    chmod u+w $steamcompattool/compatibilitytool.vdf

    runHook postInstall
  '';

  # Show "Proton-CachyOS (FSR4)" in Steam → Compatibility instead of the long
  # internal id. Only the display_name VALUE is rewritten; the internal tool
  # key (which has no spaces) is left intact so per-game compat-tool selection
  # stays stable. --replace-fail doubles as a tripwire: if a future version
  # bump changes the manifest format, the build fails loudly rather than
  # silently mis-naming the tool.
  preFixup = ''
    substituteInPlace "$steamcompattool/compatibilitytool.vdf" \
      --replace-fail '"display_name" "proton-cachyos-${finalAttrs.version}-x86_64_v3"' '"display_name" "Proton-CachyOS (FSR4)"'
  '';

  meta = {
    description = ''
      CachyOS Proton — a Steam Play compatibility tool based on Proton with
      CachyOS patches, including the FSR4 DLL-upgrade mechanism
      (PROTON_FSR4_RDNA3_UPGRADE) for RDNA3/RDNA3.5 GPUs.

      (Intended for use in the `programs.steam.extraCompatPackages` option only.)
    '';
    homepage = "https://github.com/CachyOS/proton-cachyos";
    license = lib.licenses.bsd3;
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
