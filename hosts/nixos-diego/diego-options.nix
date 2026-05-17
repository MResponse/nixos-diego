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

    # NOTE: `diego.sessionSwitch.autoLogin` option used to live here. It
    # gated a runtime-written [Autologin] conf.d entry (Plan-0001 v7
    # Option γ, commit ee2a57f). That mechanism could never work on
    # SDDM 0.21 — the daemon loads conf.d once at boot and never
    # re-reads it, so the transient [Autologin] was invisible to the
    # autologin gate. The option was removed 2026-05-17 along with the
    # zzv code. The current implementation in default.nix preselects
    # the destination session via state.conf instead (user still types
    # password once per switch, but no need to touch the session
    # dropdown). For permanent autologin, set the upstream
    # services.displayManager.{autoLogin,sddm.autoLogin.relogin} options
    # directly — see the comment block in default.nix above the
    # greeter-preselect units.

    gaming.disconnectBluetoothBeforeSwitch = lib.mkOption {
      type    = lib.types.bool;
      default = false;
      description = ''
        Plan-0003 F6 — when true, the SUPER+G keybind runs
        `bluetoothctl disconnect` before invoking
        `steamosctl switch-to-game-mode`. Saves ~2-4 s of session-switch
        wall-clock if a Bluetooth A2DP headset is connected (BlueZ's
        synchronous AVDTP teardown is on the critical path otherwise).

        Trade-off: ALL connected Bluetooth devices get dropped, including
        keyboards / mice if any. Steam-managed auto-trusted pairing
        usually reconnects audio devices inside Gamescope within a few
        seconds. Default false because no headset is paired on Diego as
        of 2026-05-17; flip to true when you start gaming with one and
        the switch feels sluggish.

        `bluetoothctl disconnect` with no connected devices exits non-zero
        silently — the `;` chaining in the keybind keeps the steamosctl
        call unconditional so this is harmless when no headset is paired.
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
