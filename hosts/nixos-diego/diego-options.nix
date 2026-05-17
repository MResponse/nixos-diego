{ lib, ... }:

# Diego-local option declarations.
#
# Split out of `default.nix` because NixOS module structure prohibits
# mixing top-level config attrs with `options = { ... }` at the same level.
# This file declares only options; `default.nix` consumes them.
#
# All options live under the `diego.*` namespace. Defaults are CONSERVATIVE
# (least surprise, lowest risk). Each option's commentary names the
# alternative and trade-offs so override is informed.
#
# See: shared-claude/Softwareprojekte/Nixos-Diego/plans/0001-login-and-gamescope-excellence.md
#      for the full reasoning behind each default.

{
  options.diego = {

    sessionSwitch.autoLogin = lib.mkOption {
      type = lib.types.enum [ "session-switch-only" "always" "off" ];
      default = "session-switch-only";
      description = ''
        Controls when SDDM autologin is in effect.

        - "session-switch-only" (DEFAULT, Plan-0001 v7 Option γ):
          Autologin marker (zzv-diego-session-switch.conf) is written
          transiently when steamos-manager writes its temp-login file
          (i.e., during SUPER+G or "Switch to Desktop"). Greeter shown
          at every cold boot. No re-auth during session switches.
          Satisfies user goals G3 (no password on session switch) AND
          G4 (one password at cold boot) simultaneously.

        - "always" (Option α): autologin every cold boot AND every
          session switch. Greeter shown only on FIRST cold boot
          (until /var/lib/diego/has-logged-in is touched by the
          first-login user service). Convenient but violates "greeter
          every boot" intent. v3 default behavior.

        - "off" (Option β): no autologin ever. Greeter at every cold
          boot AND at every session switch. Strictly honors "remove
          autologin" but adds password prompt to every Gamescope
          round-trip (no-re-auth-on-switch lost).
      '';
    };

    auth.polkitFingerprint = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable fingerprint as a sufficient PAM method on polkit-1.

        Default false because of CVE-2024-37408 — a background process
        can hijack the next finger touch to authorize an arbitrary
        privileged action (CVSS 7.3, vendor-disputed but real). The
        polkit dialog is the attention anchor for "what am I
        authorizing"; password-on-polkit preserves that.

        Set to true to accept the CVE risk in exchange for fingerprint
        on polkit GUI dialogs. Polkit prompts are rare (1-2× per week
        for typical use: mounting USB, NetworkManager Settings,
        Flatpak installs).
      '';
    };

    # Options for Phases 2/3 — declared here but consumed by gaming.nix
    # in those phases. Listed now so the namespace is coherent and so
    # diego-options.nix doesn't need re-editing during later phases.

    gamescope = {
      hdr = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          When true, sets STEAM_GAMESCOPE_FORCE_HDR_DEFAULT=1 and
          STEAM_GAMESCOPE_FORCE_OUTPUT_TO_HDR10PQ_DEFAULT=1 in
          jovian.steam.environment, making HDR on-by-default per game
          in Steam UI.

          Default false despite user-stated "ON in Phase 2" preference
          (Plan v1→v3) because of:
            - gamescope#1006: HDR+VRR refresh-rate oscillation on
              non-multiplane hardware (Strix Halo DCN 3.5 IS
              non-multiplane)
            - gamescope#1076 / #1887: HDR hotplug black-screen failure
              modes (Bazzite explicitly warns)
            - Hardware reality on kernel 7.0.5: native HDMI to LG C2
              cannot do HDR anyway (TMDS bandwidth limit)

          The override is one line. Recommended path: leave false until
          (a) Cable Matters DP→HDMI 2.1 adapter + empirical validation,
          OR (b) kernel 7.2+ with DCN 3.5 FRL.
        '';
      };

      vrr = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          When true, adds --adaptive-sync to the gamescope CLI via the
          overlay-prePatch. Default false because of gamescope#1006
          (HDR+VRR oscillation) and LG C2 OLED brightness flicker in
          dark scenes with HDMI Forum VRR.

          Even when false, Steam's per-game VRR toggle in QAM still
          works (STEAM_GAMESCOPE_VRR_SUPPORTED=1 is set unconditionally
          by Jovian's script). Set to true to enable VRR globally.
        '';
      };

      refreshRange = lib.mkOption {
        type = lib.types.strMatching "[0-9]+,[0-9]+";
        default = "30,120";
        description = ''
          Value for STEAM_DISPLAY_REFRESH_LIMITS — bounds the Steam
          QAM refresh slider as "min,max" range. Must be two integers
          separated by a comma.

          Examples:
            "30,120"  - LG C2 + internal OLED (default)
            "24,165"  - typical gaming-monitor range
            "20,240"  - includes esports displays
            "40,90"   - Steam Deck OLED (Galileo) defaults
            "40,60"   - Steam Deck LCD (Jupiter) defaults
        '';
      };

      preferOutputOverride = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf lib.types.str);
        default = null;
        example = [ "HDMI-A-1" "eDP-1" ];
        description = ''
          Override list for the gamescope --prefer-output argument.

          When null (default), the pre-start hook auto-enumerates
          connected outputs sorted by EDID pixel-rate
          (resolution × refresh).

          When set to a non-null list, that list is used verbatim,
          bypassing the heuristic. Use for:
            - Forcing a specific external regardless of heuristic
            - Pinning internal panel during testing (`[ "eDP-1" ]`)
            - Replicating v3's simple chain
              (`[ "DP-1" "DP-2" "HDMI-A-1" "eDP-1" ]`)

          When set AND not all listed connectors are connected,
          gamescope picks the first connected one from the list
          (its normal -O semantic). No auto-fallback to other
          connectors.
        '';
      };
    };
  };
}
