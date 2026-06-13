{
  config,
  lib,
  pkgs,
  username,
  inputs,
  ...
}:

let
  # Qylock SDDM theme bundle (Plan-0004 Phase 1, ADR-0026).
  # Wrapper theme `qylock-random` rolls a sub-theme on every greeter spawn.
  qylockThemes = pkgs.callPackage ./qylock-themes.nix { };
in

{
  imports = [
    ../../modules/desktop.nix
    ../../modules/gaming.nix
    # Jovian-Modul direkt im Host (statt zentral in mkDesktopHost in flake.nix),
    # damit Donvinis `dracula` das Modul nicht sieht. Donvini's mkDesktopHost
    # sammelt die geteilten Inputs (hyprland, sops-nix, lsfg-vk-flake) in der
    # zentralen modules-Liste; Diego-spezifisches landet hier per-host. Trade-off:
    # zwei Composition-Patterns in einer Codebase — aber sauberer als die
    # zentrale mkDesktopHost-Liste für einen Single-Host-Eintrag aufzubohren.
    inputs.jovian-nixos.nixosModules.default
    ./diego-options.nix      # Diego-local Nix options (Plan-0001 v7 §5)
    ./gaming.nix
    ./hardware.nix
    ./services.nix
    ./security.nix
    ./power-modes.nix
    ./ac-power-mode.nix      # AC plugged → performance, unplugged → smart-sense (ADR-0037)
    ./gamescope-power.nix    # Plan-0002 §2.4 — force `performance` while Gamescope is active
    ./vr.nix                 # SteamVR cap + Steam Link VR firewall (ADR-0027)
    ./tailscale.nix          # Tailscale mesh — diego↔xardas SSH (shared-claude Infrastruktur/Tailscale; ADR-0005 trigger)
  ];

  # Five-mode power management replicating HP's Windows myHP modes
  # (Smart Sense / Performance / Cool / Quiet / Power Saver) on top of ppd.
  # See ./power-modes.nix and shared-claude/Softwareprojekte/Nixos-Diego/
  # adr/0024-five-mode-power-system.md.
  services.powerModes = {
    enable = true;
    defaultMode = "smart-sense";
  };

  # Plan-0006 F3b-Extension — enable Fingerabdruck im polkit-Stack.
  # NOETIG damit KeePassXC's Polkit Quick Unlock tatsaechlich den Finger
  # statt Passwort nutzt. Polkit-Dialog konsultiert /etc/pam.d/polkit-1;
  # ohne diese Option waere fprintd dort nicht eingehangen.
  #
  # Trade-off: CVE-2024-37408 (polkit fprintd hijack — disputed, unpatched
  # per 2026-04). Exploit-Pfad: malicious process running as marius
  # triggert eine polkit-action waehrend Marius vor dem Reader sitzt;
  # naechster Finger-Tap autorisiert die Attacker-Action statt der
  # erwarteten. Diego ist Single-User-Laptop, kein untrusted code als
  # marius — Risk akzeptabel fuer den UX-Win von Fingerabdruck-KeePassXC
  # (Marius's expliziter Wunsch "ideal waere Fingerabdruck").
  #
  # Revert: Wert auf `false` setzen (oder Zeile entfernen) →
  # polkit-Dialog zurueck zu Password-only.
  diego.auth.polkitFingerprint = true;

  # Boot-menu label: identifies generations built from this baseline as the
  # known-good post-Plan-0002 stable point (session-switch UX + Gamescope
  # power-mode integration verified end-to-end 2026-05-17). When picking a
  # generation in systemd-boot, look for "stable-plan0002" in the entry name.
  # Update this string when a new milestone ships (Plan-0003 etc.).
  system.nixos.label = "stable-plan0002";

  # ── Session-switch speedups (Plan-0002 §2.3) ─────────────────────────
  #
  # 1. Disable coredump storage. Electron apps (Discord, Slack, browsers)
  #    SIGTRAP on shutdown during a session switch; default systemd-coredump
  #    serializes the full process image to /var/lib/systemd/coredump/,
  #    blocking the stop transaction. Observed 2026-05-17: ~54 s on a single
  #    Discord crash. Storage=none + ProcessSizeMax=0 together hit the early
  #    return in coredump-submit.c:274-277 BEFORE the kernel pipe is drained
  #    (agent 4 in roast-loop). The journal still logs "process crashed"; we
  #    just don't keep the core file. Re-enable for debugging via:
  #      sudo systemctl edit --runtime systemd-coredump@.service
  systemd.coredump.settings.Coredump = {
    Storage = "none";
    ProcessSizeMax = 0;
  };

  # 2. Bound user-scope app stop timeout. Default 90 s default-timeout means
  #    heavy desktop apps (Discord, browsers, terminals with claude code
  #    running) graceful-stop too slowly for a gaming session switch. 5 s is
  #    enough for shells (Helix, Emacs, fish) to react cleanly; what doesn't
  #    react gets SIGKILL'd.
  #
  #    RISK: Marius's helix has no autosave (~/.config/helix/config.toml lacks
  #    `editor.auto-save = true`). Unsaved buffers in helix at session-switch
  #    time will be lost. Recommend enabling helix autosave as a follow-up.
  #
  #    Caelestia / wayland-wm@hyprland already have explicit short
  #    TimeoutStopSec (5s / 10s); they're unaffected. The change pulls
  #    udiskie / mpd / gammastep / hyprpaper / mako / syncthing / app-*.scope
  #    from 90 s to 5 s. Syncthing flush-on-SIGTERM completes within 5 s in
  #    typical state; it's crash-tolerant otherwise.
  systemd.user.extraConfig = ''
    DefaultTimeoutStopSec=5s
    DefaultTimeoutAbortSec=3s
  '';

  # 3. Outer cap on the user manager itself — if the user@1000.service
  #    aggregate stop doesn't complete in 10 s, SIGKILL the whole thing.
  #    Defense-in-depth in case a stuck child service holds up the
  #    transaction past the per-unit timeout.
  systemd.services."user@".serviceConfig.TimeoutStopSec = "10s";

  networking = {
    hostName = "nixos-diego";
    networkmanager.enable = true;
    useDHCP = lib.mkDefault true;
  };

  # German keyboard everywhere — override modules/hyprland/default.nix's "us"+caps:escape
  services.xserver.xkb = {
    layout = lib.mkForce "de";
    variant = lib.mkForce "";
    options = lib.mkForce "";
  };
  console.keyMap = "de";

  # Disable KDE Kwallet PAM integration: Marius uses KeePassXC (via keepmenu),
  # not kwallet. Donvini's modules/desktop.nix enables pam_kwallet5 for `login`,
  # which spawns `ksecretd --pam-login`. On Diego the helper hangs in
  # unix_accept() after PAM session-open, blocking the gdm-wayland-session
  # exec and freezing the GDM password screen indefinitely (login hangs with
  # the password field still populated). Override per-host so future pulls of
  # donvini's modules/desktop.nix don't conflict.
  security.pam.services.login.enableKwallet = lib.mkForce false;

  # Display Manager: SDDM statt Donvinis GDM (Jovian-NixOS-Constraint).
  # Jovian's steamos-manager registriert das DBus-Interface
  # `com.steampowered.SteamOSManager1.SessionManagement1` nur wenn
  # `/etc/sddm.conf.d/steamos.conf` existiert (steamos-manager/src/session.rs:94).
  # Ohne dieses Interface schlägt `steamosctl switch-to-game-mode` mit
  # "UnknownInterface" fehl — also funktioniert das nahtlose Session-Switching
  # zwischen Hyprland und Gaming Mode nur mit SDDM.
  #
  # WICHTIG: Jovian's modules/steam/autostart.nix:96 schreibt steamos.conf
  # NUR im `mkIf cfg.autoStart`-Block. Diego nutzt `jovian.steam.autoStart = false`
  # (kein Auto-Boot in Gamescope), also provisioniert Jovian die Datei nicht.
  # Wir müssen sie selbst anlegen, sonst ist der ganze SDDM-Wechsel umsonst.
  #
  # Donvinis modules/hyprland/default.nix aktiviert GDM upstream; per mkForce
  # Diego-only auf SDDM gestellt. Die Kopplung an Jovian wird via `mkIf` an
  # `jovian.steam.enable` gehängt — wenn Jovian je deaktiviert wird, fällt
  # auch der DM-Override weg und GDM kommt zurück. Details: ADR-0008.
  services.displayManager.gdm.enable =
    lib.mkIf config.jovian.steam.enable (lib.mkForce false);
  services.displayManager.sddm = lib.mkIf config.jovian.steam.enable {
    enable = true;
    wayland.enable = true;

    # ── Greeter compositor: weston (NixOS-Default) ──────────────────────
    # 2026-06-05: Versuch `wayland.compositor = "kwin"` (gegen den unsichtbaren
    # Cursor) WIEDER ENTFERNT — kwin_wayland funktioniert auf Diego NICHT als
    # SDDM-Greeter-Compositor: Journal zeigte
    #   kwin_wayland_drm: drmModeListLessees() failed: Permission denied
    #   kwin_wayland_drm: Atomic modeset test failed! Permission denied
    #   kwin_core: Failed to find a working output layer configuration!
    # → kwin bekam keinen DRM-Master/Atomic-Modeset, malte nur die
    #   HW-Cursor-Plane (Cursor sichtbar!) aber NICHT die Primary-Plane →
    #   "Cursor + Rest schwarz". Zusätzlich QQuickView-layer-shell-Konflikt
    #   (QT_WAYLAND_SHELL_INTEGRATION=layer-shell) → Greeter-Fenster mappte nicht.
    # Diego rollte 2026-06-05 zurück auf gen-82 (weston). Der Cursor-Fix muss
    # anders gelöst werden (weston-Software-Cursor o.ä.), NICHT via kwin.
    # Siehe Memory diego-sddm-cursor-weston-compositor-not-theme.

    # Plan-0003 F5: cursor settings live in [Theme] (verified against SDDM
    # source — Configuration.h:80-85 has NO [Wayland] CursorTheme key;
    # Greeter.cpp:104,107 reads mainConfig.Theme.CursorTheme + CursorSize and
    # exports them as XCURSOR_THEME / XCURSOR_SIZE at Greeter.cpp:151,208).
    #
    # libwayland-cursor in the greeter Wayland session resolves the theme
    # name against /run/current-system/sw/share/icons (system XCURSOR_PATH),
    # which is why we also need pkgs.bibata-cursors in environment.system-
    # Packages below — Marius's user-installed Bibata in ~/.local/share/icons/
    # isn't visible to the sddm user.
    #
    # Plan-0004 v6 supersedes the v5 "Qt6 theme swap is a future plan" note:
    # `theme = "qylock-random"` activates the qylockThemes bundle's wrapper
    # theme, which rolls a random sub-theme via QML Loader on every greeter
    # spawn. Cursor + theme are independent ([Theme] keys; Current= +
    # CursorTheme=/CursorSize= coexist).
    theme = "qylock-random";
    extraPackages = [ qylockThemes ];
    settings.Theme = {
      CursorTheme = "Bibata-Modern-Ice";
      CursorSize  = 24;
    };
  };

  # (2026-06-05: getestet `services.displayManager.environment.WESTON_DISABLE_ATOMIC=1`
  # gegen den unsichtbaren Cursor — VERWORFEN: erreicht weston gar nicht. Der
  # sddm-Daemon-Env propagiert NICHT zu weston (weder XCURSOR noch WESTON_*;
  # weston bekommt wie der Greeter ein gefiltertes Env). Um weston ein Env zu
  # geben bräuchte es einen compositorCommand-Override mit `env …` davor — und
  # damit die weston.ini-Keymap-Neuableitung (Plan-0016-Risiko). Cursor-Fix
  # bleibt offen; siehe Memory diego-sddm-cursor-weston-compositor-not-theme.)

  # Plan-0003 F5: system-install Bibata-Modern-Ice so the SDDM greeter
  # (running as user `sddm`) can find it. Matches Marius's GTK cursor theme
  # (~/.config/gtk-3.0/settings.ini) for visual consistency between Hyprland
  # and the greeter.
  environment.systemPackages = lib.mkIf config.jovian.steam.enable [
    pkgs.bibata-cursors
    qylockThemes  # Plan-0004 Phase 1 — see qylock-themes.nix + ADR-0026
  ];

  # Plan-0003 F5: remove the stale, unmanaged /etc/sddm.conf.d/theme.conf
  # (mtime 2026-05-15 12:36, predates current flake; sets [Theme] Current=
  # maldives which forces fallback every greeter spawn). After removal, SDDM
  # has no Current= override and uses its built-in default theme. Our cursor
  # settings via services.displayManager.sddm.settings.Theme above still apply
  # (different keys, no conflict).
  system.activationScripts.diego-sddm-stale-theme-conf =
    lib.mkIf config.jovian.steam.enable {
      text = ''
        if [ -f /etc/sddm.conf.d/theme.conf ] && [ ! -L /etc/sddm.conf.d/theme.conf ]; then
          ${pkgs.coreutils}/bin/rm -f /etc/sddm.conf.d/theme.conf
        fi
      '';
      deps = [ ];
    };

  # Manuelle Provisionierung der steamos.conf — siehe Kommentar oben.
  # Inhalt ist leer; steamos-manager prüft nur die Existenz der Datei
  # (steamos-manager/src/session.rs:94, `is_session_managed()` via
  # `try_exists(path)`). Dieselbe leere Datei legt Jovian's autostart.nix:96
  # bei autoStart=true an — wir replizieren das Verhalten für autoStart=false.
  environment.etc."sddm.conf.d/steamos.conf" =
    lib.mkIf config.jovian.steam.enable { text = ""; };

  # Hyprland MUSS via UWSM laufen, sonst ist `steamosctl switch-to-game-mode`
  # nur halb wirksam: session.rs:logout() stoppt `graphical-session.target`,
  # damit SDDM die per zzt-steamos-temp-login.conf gesetzte Gamescope-Session
  # einloggt. Ohne UWSM ist Hyprland aber kein systemd-Unit (SDDM startet
  # `start-hyprland` direkt als Session-Exec), die Target-Hierarchie reisst
  # alle WantedBy-User-Services (caelestia, portals, indicator, signal, …)
  # ab — Hyprland selbst überlebt jedoch. SDDM sieht kein Session-Ende, der
  # Autologin-Handoff feuert nie, und der User sitzt in einem Compositor mit
  # totem Bar/Notification/Focus-Stack fest (Workspace-2 = 0 Fenster, Input
  # geht nirgendwohin).
  #
  # Wichtig: `programs.hyprland.enable = true` installiert NUR die
  # `hyprland-uwsm.desktop`-Session-Datei in wayland-sessions/, NICHT das
  # `uwsm`-Binary selbst. Eine frühere Iteration dieses Blocks setzte nur
  # `defaultSession = "hyprland-uwsm"` und kassierte beim Autologin ein
  # `exit 127` (uwsm not in PATH) → SDDM fiel auf den Greeter zurück, dort
  # war Gamescope aus `state.conf [Last]` preselected. `withUWSM = true`
  # darunter zieht das Binary + systemd-Target-Setup mit (siehe nixpkgs
  # `programs.hyprland.withUWSM`) und ist die Voraussetzung dafür, dass
  # `defaultSession = "hyprland-uwsm"` überhaupt funktioniert.
  #
  # `mkForce` ist nötig, weil Donvini's modules/hyprland/default.nix:10
  # upstream explizit `defaultSession = "hyprland"` setzt. Die Kopplung an
  # Jovian macht den Override automatisch reversibel: ohne Jovian läuft
  # Diego wieder mit Donvini's Plain-Hyprland-Default. Details: ADR-0017.
  programs.hyprland.withUWSM = lib.mkIf config.jovian.steam.enable true;
  services.displayManager.defaultSession =
    lib.mkIf config.jovian.steam.enable (lib.mkForce "hyprland-uwsm");

  # ── Cold-boot autologin: NOT configured ─────────────────────────────
  #
  # User explicitly chose greeter on every cold boot ("Remove autologin"
  # answer 2026-05-17 ~01:25). Plan-0001 v7 originally tried to also
  # bypass the greeter during session switches via a transient
  # [Autologin] in conf.d (the zzv mechanism, commits ee2a57f and
  # follow-ups). That never worked: SDDM 0.21's daemon loads conf.d
  # once at boot and never re-reads it, so a runtime-written [Autologin]
  # is invisible to the autologin gate. The zzv code was removed
  # 2026-05-17 ~18:55 and replaced by the greeter-preselect mechanism
  # below, which writes /var/lib/sddm/state.conf so the greeter
  # (re-spawned per display transition) preselects the correct
  # destination session — user still types password once per switch,
  # but doesn't have to touch the session dropdown.
  #
  # If you ever want true autologin (no password during switches OR at
  # cold boot, matching Jovian's autoStart=true setup), set:
  #     services.displayManager.autoLogin.enable = true;
  #     services.displayManager.autoLogin.user = username;
  #     services.displayManager.sddm.autoLogin.relogin = true;
  # That writes [Autologin] User=… permanently into NixOS-managed
  # conf.d, present at SDDM startup so the daemon's autologin gate
  # latches at boot. Boot would then go straight into the default
  # session, bypassing the greeter entirely.

  # ── Session-switch greeter preselect ─────────────────────────────────
  # When steamos-manager triggers a session switch (SUPER+G into Gamescope
  # or "Switch to Desktop" out of Gamescope) it writes the destination
  # session into /etc/sddm.conf.d/zzt-steamos-temp-login.conf, then stops
  # graphical-session.target. SDDM transitions to a new display and spawns
  # the greeter, which preselects whichever session is recorded in
  # /var/lib/sddm/state.conf as `[Last] Session=`.
  #
  # By default state.conf was last written when the user logged INTO the
  # session that just ended — exactly the wrong preselect for a switch.
  # So when we observe steamos-manager's zzt CLOSE_WRITE, we immediately
  # rewrite `[Last] Session=` to point at the destination. The greeter
  # (a fresh Qt process per display transition) reads our corrected
  # state.conf at process startup → preselects the right session → user
  # types the password and lands in Gamescope (SUPER+G) or Hyprland
  # (Switch to Desktop) without touching the session dropdown.
  #
  # Why this scheme is race-safe (per SDDM 0.21.0 source, agent 1 in
  # roast-loop, file:line cited inline):
  #   - state.conf is written ONLY at slotAuthenticationFinished(success=
  #     true) — src/daemon/Display.cpp:484-496 — i.e., AFTER the user
  #     types the password.
  #   - The greeter reads state.conf at process startup — src/greeter/
  #     SessionModel.cpp:167-173.
  #   - Therefore between zzt-CLOSE_WRITE and greeter-Qt-startup, our
  #     write window is wide open. Empirical latency 2026-05-17 19:55:
  #     path-unit fires within 5 ms of zzt CLOSE_WRITE; script completes
  #     in ~50 ms. Greeter Qt+theme spawn takes hundreds of ms minimum.
  #     Margin ≥ 20×.
  #
  # Why state.conf rather than [Autologin] in conf.d? SDDM 0.21's daemon
  # loads its conf.d ONCE at boot and never re-reads it (verified by
  # strace 2026-05-17: zero openat() of sddm.conf.d after startup, even
  # when conf.d files are modified). Writing [Autologin] User+Session
  # into conf.d during a switch is invisible to the daemon's autologin
  # gate, which is frozen from boot.
  #
  # NO `after = diego-sddm-wipe-stale-gamescope-login.service` directive
  # — earlier v2 attempt created an ordering cycle through paths.target
  # ↔ basic.target. PathChanged is IN_CLOSE_WRITE-only (empirically
  # tested 2026-05-17 19:57: 1 fire on write, 0 fires on delete), so a
  # stale zzt at boot can't trigger us spuriously. The defense was
  # solving a non-problem.
  systemd.paths.diego-greeter-preselect-on-zzt = lib.mkIf
    config.jovian.steam.enable {
      description = "Watch zzt CLOSE_WRITE → immediate state.conf rewrite for next greeter cycle";
      wantedBy = [ "multi-user.target" ];
      pathConfig.PathChanged = "/etc/sddm.conf.d/zzt-steamos-temp-login.conf";
    };

  systemd.services.diego-greeter-preselect-on-zzt = lib.mkIf
    config.jovian.steam.enable {
      description = "Immediately rewrite SDDM state.conf [Last] Session= to match zzt's Session=, so the next greeter preselects the destination session";
      # steamos-manager observed to CLOSE_WRITE zzt up to 6× in <1s during
      # a single switch (multi-syscall write). Disable rate-limit; script
      # is idempotent so duplicate fires are harmless.
      unitConfig.StartLimitIntervalSec = 0;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "diego-greeter-preselect" ''
          set -euo pipefail
          zzt=/etc/sddm.conf.d/zzt-steamos-temp-login.conf
          state=/var/lib/sddm/state.conf
          # Bail conditions: no switch in progress, or state.conf doesn't
          # exist yet (no prior login → nothing to preselect from).
          [ -f "$zzt" ]   || exit 0
          [ -f "$state" ] || exit 0
          # Destination session basename (e.g. "gamescope-wayland.desktop"
          # for SUPER+G, "hyprland-uwsm.desktop" for Switch to Desktop).
          target=$(sed -n 's/^Session=//p' "$zzt" | head -1)
          [ -n "$target" ] || exit 0
          # Derive SessionDir prefix from current state.conf value. SDDM
          # uses full /nix/store paths in [Last] Session=, e.g.
          # /nix/store/<hash>-desktops/share/wayland-sessions/<sess>.desktop;
          # we must match the same format so SessionModel's string
          # comparison hits (greeter/SessionModel.cpp:169).
          current=$(sed -n 's/^Session=//p' "$state" | head -1)
          [ -n "$current" ] || exit 0
          sess_dir=$(dirname "$current")
          sess_path="$sess_dir/$target"
          # Sanity: destination .desktop file must exist; if not, leave
          # state.conf alone (the greeter will fall back to whatever was
          # last selected).
          [ -f "$sess_path" ] || exit 0
          # Idempotent: already correct → no-op.
          [ "$current" = "$sess_path" ] && exit 0
          # Atomic rewrite. state.conf currently has only [Last]; a global
          # ^Session= match is therefore safe.
          sed -i "s|^Session=.*|Session=$sess_path|" "$state"
        '';
      };
    };

  # ── Boot-time cleanup of stale steamos-manager temp-login ────────────
  # Wipes /etc/sddm.conf.d/zzt-steamos-temp-login.conf at every boot,
  # before SDDM reads its conf.d. Defends against the failure mode where
  # steamos-manager crashed mid-switch leaving zzt behind — would cause
  # SDDM to autologin into Gamescope on every subsequent boot ("stuck in
  # Gamescope" trap — ADR-0017).
  #
  # v3: zzv-diego-session-switch.conf removed from the wipe list — the
  # Plan-0001 v7 conf.d-autologin mechanism was abandoned in favor of
  # state.conf preselect (above). No nixos-diego boot writes zzv anymore.
  # Ordered before display-manager.service via `before` + after `local-fs`.
  systemd.services.diego-sddm-wipe-stale-gamescope-login =
    lib.mkIf config.jovian.steam.enable {
      description = "Wipe stale session-switch autologin files at boot";
      before = [ "display-manager.service" ];
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # v3 (Plan-0002): zzv path dropped; we no longer write zzv since the
        # conf.d-autologin scheme was abandoned for state.conf preselect.
        ExecStart = "${pkgs.coreutils}/bin/rm -f /etc/sddm.conf.d/zzt-steamos-temp-login.conf";
      };
    };

  # Fingerprint biometric authentication. ZBook Ultra G1a ships with a
  # Synaptics 06cb:0106 reader, supported natively by libfprint's "Synaptics
  # Sensors" driver (no proprietary libfprint-2-tod needed).
  #
  # Earlier approach: keep pam_fprintd in /etc/pam.d/{sddm,login,sudo} but
  # move it AFTER pam_unix (sufficient short-circuit on password success).
  # On paper this lets the user type password → pam_unix succeeds → stack
  # returns without ever firing pam_fprintd. In practice on Diego's SDDM
  # greeter the UX still felt mandatory — the sensor LED arms whenever
  # fprintd is in the auth chain, and the Maldives theme doesn't communicate
  # "may scan OR type password" vs. "must scan AND type password", so Marius
  # consistently placed his finger anyway and read that as required.
  #
  # New approach: strip pam_fprintd from the user-facing /etc/pam.d/*
  # entirely — make password unambiguously sufficient at every PAM prompt.
  # fprintd daemon stays enabled because Caelestia's lock screen consumes
  # fprintd via its OWN bundled PAM stack (caelestia-shell/assets/pam.d/passwd,
  # which contains only pam_unix.so) plus a separate Quickshell `fprint`
  # PamContext that talks to fprintd over DBus — neither path goes through
  # /etc/pam.d/, so stripping fprintd here does not break the optional-touch
  # unlock on the lock screen.
  #
  # Services stripped:
  #   - sddm: greeter — eliminates the perceived-mandatory prompt at the
  #     cold-boot greeter and at the per-switch greeter that we now also
  #     show (no autologin in our setup; see comment block above).
  #   - login: TTY — same reason; SDDM substacks `login` so this also affects
  #     the substacked auth path.
  #   - polkit-1: CVE-2024-37408 — `auth sufficient pam_fprintd.so` on
  #     polkit-1 lets a background process hijack the next finger touch to
  #     authorize an arbitrary privileged action (CVSS 7.3, vendor-disputed
  #     but real). The polkit GUI dialog is the only attention anchor for
  #     "what am I authorizing"; password-only there is a security gain on
  #     top of the UX win.
  #
  # sudo KEEPS fprintAuth: TTY sudo prints "Place finger on sensor" next to
  # the command about to run, so Marius sees exactly what's being authorized
  # (no hijack window). The pam_unix-before-pam_fprintd reorder below makes
  # password-first the default — fingerprint only fires on an empty/wrong
  # password.
  #
  # Note: services like su / passwd / chsh / cups / swaylock still have
  # pam_fprintd by NixOS default (fprintAuth = services.fprintd.enable = true).
  # They're left untouched because they're rarely hit interactively and the
  # cleanup-burden isn't worth the noise. If any of them become friction-
  # points later, add a per-service `fprintAuth = lib.mkForce false;` line.
  services.fprintd.enable = true;
  security.pam.services = {
    # Plan-0006 F2b — re-enable fingerprint on SDDM (login substack).
    # Maldives-theme-blocker (alte Begruendung fuer `login.fprintAuth =
    # lib.mkForce false`) ist obsolet seit qylock-random (Plan-0004/5).
    # qylock-themes rendern PAM-Conversation-Messages NICHT visuell —
    # Workflow: Marius drueckt Enter auf LEEREM Passwort-Feld → fprintd
    # activates silently → Finger touch → login. Gilt fuer Cold-Boot UND
    # Gamescope-Switch (gleicher PAM-Stack). pam_unix-before-pam_fprintd
    # order (NixOS PR #171140) macht password-first sicher — Reader-Fail
    # bricht nicht Login.
    # (login.fprintAuth = true ist NixOS-default wenn services.fprintd.enable;
    # daher kein expliziter Eintrag noetig — wir entfernen nur den
    # `mkForce false` override.)

    # polkit-1: configurable via diego.auth.polkitFingerprint (Plan v7 §5.1).
    # Default false (CVE-2024-37408). Set true to accept CVE risk in exchange
    # for fingerprint on polkit GUI dialogs.
    "polkit-1".fprintAuth = lib.mkForce config.diego.auth.polkitFingerprint;
    sudo.fprintAuth = true;
  };

  # Move pam_fprintd AFTER pam_unix on the surfaces where fprintd is enabled.
  # Relative offset per NixOS pam.nix docs — absolute order values are
  # subject to nixpkgs renumbering.
  security.pam.services.sudo.rules.auth.fprintd.order =
    config.security.pam.services.sudo.rules.auth.unix.order + 10;
  # Plan-0006 F2b — selbe ordering fuer login (das SDDM-greeter via
  # substack nutzt). Ohne diese reorder waere pam_fprintd at order 11400
  # vor pam_unix 11700 → fprintd-first-prompt → "30s hang bei
  # password-typing" Bug (sddm/sddm#1840). Reorder macht password-first
  # Default; Fingerabdruck nur bei leerem/falschem Passwort.
  security.pam.services.login.rules.auth.fprintd.order =
    config.security.pam.services.login.rules.auth.unix.order + 10;
  # Conditional polkit-1 ordering: only applies when the option enables fprintd
  # on polkit. When false, pam_fprintd isn't in the polkit stack at all and
  # the rule is dropped.
  security.pam.services."polkit-1".rules.auth.fprintd.order =
    lib.mkIf config.diego.auth.polkitFingerprint
      (config.security.pam.services."polkit-1".rules.auth.unix.order + 10);

  # Skip the polkit-agent password prompt for fingerprint enrollment.
  # Default polkit policy requires `auth_self` (user must enter password in
  # an agent dialog), which on a single-user Hyprland session adds friction
  # without real security gain — anyone with shell as marius already could
  # enroll a finger after re-authenticating, and physical access to the
  # laptop is the only way enrollment is useful. Limit the bypass narrowly
  # to the enroll/delete-enrolled-fingers actions for user marius.
  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if (subject.user == "marius" &&
          (action.id == "net.reactivated.fprint.device.enroll" ||
           action.id == "net.reactivated.fprint.device.setusername")) {
        return polkit.Result.YES;
      }
    });
  '';

  # Plan-0006 F3b — KeePassXC develop-snapshot Overlay fuer Polkit Quick
  # Unlock (Fingerabdruck-basierter DB-unlock). KeePassXC 2.8 ist unreleased;
  # develop hat PR #8983 gemerged. Overlay greift global (HM keepmenu.nix
  # + system gleich), kein PATH-conflict. Re-pin monthly oder bei Bedarf.
  # Drop overlay wenn nixpkgs 2.8.0 ships → Plan-0007.
  nixpkgs.overlays = [ (import ../../pkgs/keepassxc-overlay.nix) ];

  # (keepassxc ist bereits in services.nix environment.systemPackages —
  # die Overlay-Aenderung greift dort transparent. Polkit-policy-Pfad
  # /run/current-system/sw/share/polkit-1/actions/ wird via dem
  # existierenden systemPackages-Eintrag versorgt.)

  # Plan-0006 F1 — Touchpad/Touchscreen-Access im SDDM-Greeter.
  # Diego's i2c-HID Pointer-Devices (Synaptics-Touchpad, ELAN-Touchscreen)
  # bekommen ohne extra rule weder seat-tag noch ACL — sddm-user (kein
  # input-group) kann /dev/input/event* nicht oeffnen → weston-kiosk im
  # Greeter sieht keine Pointer-Events.
  #
  # Keyboard funktioniert nur accidentally weil STEAMOS_POWER_BUTTON-rule
  # (70-steamos-power-button.rules) ihm uaccess+seat anhaengt.
  #
  # Diese rule fuegt seat0+uaccess fuer Touchpad+Touchscreen hinzu.
  # - SDDM-greeter (sddm user, active seat0) bekommt rw-ACL → weston-kiosk +
  #   libinput koennen lesen.
  # - Marius-session (marius user) bekommt selbe ACL — Hyprland nutzt's
  #   nicht direkt (geht ueber libseat fd-passing), aber redundant ist OK.
  #
  # Security: ID_INPUT_MOUSE (external USB-Mice) NICHT getaggt — vermeidet
  # ungewollten Override von Device-spezifischen udev-Quirks; bei Bedarf
  # erweiterbar.
  services.udev.extraRules = ''
    SUBSYSTEM=="input", KERNEL=="event*", ENV{ID_INPUT_TOUCHPAD}=="1", TAG+="uaccess", TAG+="seat", ENV{ID_SEAT}="seat0"
    SUBSYSTEM=="input", KERNEL=="event*", ENV{ID_INPUT_TOUCHSCREEN}=="1", TAG+="uaccess", TAG+="seat", ENV{ID_SEAT}="seat0"
  '';

  # Expose marius' shared-claude commands and agents to `sudo claude` sessions.
  # Claude Code reads ~/.claude/ from $HOME; `sudo claude` runs with HOME=/root
  # (sudoers env_keep does not preserve HOME on NixOS), so /root/.claude/ is
  # consulted instead of /home/marius/.claude/ where the symlinks live. Without
  # this script, root-side Claude sees zero custom slash-commands (/held, /hero,
  # /patchday, …) and no custom agents. Re-creating /root/.claude/{commands,agents}
  # as symlinks into the Syncthing-backed shared-claude tree keeps both contexts
  # in sync. ln -sfn is idempotent across rebuilds; root keeps its own
  # plugins/sessions/history/settings, which is intentional.
  system.activationScripts.mariusSharedClaudeRootLinks = {
    text = ''
      mkdir -p /root/.claude
      ln -sfn /home/marius/Syncthing_lighteningv1.0/Technisches/shared-claude/commands /root/.claude/commands
      ln -sfn /home/marius/Syncthing_lighteningv1.0/Technisches/shared-claude/agents   /root/.claude/agents
    '';
    deps = [ "users" ];
  };

  nix = {
    settings.trusted-users = [ "${username}" ];
    gc.dates = "weekly";
  };

  users.users."${username}" = {
    isNormalUser = true;
    extraGroups = [
      "networkmanager"
      "wheel"
      "docker"
      "libvirtd"
      "audio"
      "video"
      "tss"  # Plan-0014 — TPM2-Zugriff fuer systemd-creds (KeePassXC auto-unlock)
    ];
    packages = with pkgs; [ ];
  };

  # ─────────────────────────────────────────────────────────────────────
  # Second user — acrm (Tier-1 Microsoft 365 work identity).
  #
  # Shares the caelestia desktop (same Hyprland-UWSM session as marius) but is
  # ISOLATED: NOT in `wheel` (no sudo), NOT in `trusted-users` (line ~545 stays
  # marius-only), NOT in `tss`/`docker`/`libvirtd`. Gets only the desktop
  # groups needed to actually use the laptop.
  #
  # The Microsoft tooling (Edge/Teams/OneDrive) lives in home-acrm.nix →
  # hm-modules/ms365.nix and — via home-manager.useUserPackages = true — lands
  # ONLY in /etc/profiles/per-user/acrm, never on marius's PATH. No
  # services.intune yet (that's Tier-2, pending the Conditional-Access test:
  # acrm signs Edge into Teams/SharePoint and we see whether CA admits it).
  #
  # Wired HERE (not in flake.nix's shared mkDesktopHost) so acrm stays scoped
  # to THIS host — dracula never gets an acrm HM user and `nix flake check`
  # stays green. home-manager.users merges with the marius entry from flake.nix
  # and inherits the same extraSpecialArgs/useUserPackages.
  # ─────────────────────────────────────────────────────────────────────
  users.users.acrm = {
    isNormalUser = true;
    description = "ACRM (Microsoft 365 work account)";
    extraGroups = [
      "networkmanager"
      "audio"
      "video"
      "render" # iGPU access; marius gets it via his other groups
    ];
    packages = with pkgs; [ ]; # home-manager owns acrm's packages (home-acrm.nix)
  };

  # acrm's home-manager config: curated caelestia-desktop subset + ms365.nix.
  # The global extraSpecialArgs (username/mail/fullName = marius) still flow in,
  # so home-acrm.nix deliberately ignores those args and hardcodes acrm.
  home-manager.users.acrm = import ../../home-acrm.nix;

  # Plan-0014 — TPM2 fuer KeePassXC initial-unlock ohne Master-PW-Typing.
  # `systemd-creds encrypt --tpm2-device=auto` bindet ein Credential an die
  # TPM2-Hardware (HP ZBook). Disk-stolen Angreifer kann das verschluesselte
  # Credential nicht entschluesseln ohne den TPM-Chip dieser Maschine.
  #
  # `abrmd.enable = false` weil systemd-creds direkt /dev/tpmrm0 nutzt
  # (kernel-resident TPM Resource Manager) — der user-space tpm2-abrmd-
  # Daemon ist nicht noetig und verbraucht nur Speicher.
  #
  # Die `tss`-Gruppe wird von nixpkgs's security.tpm2-modul deklariert
  # und auf /dev/tpmrm0 ueber udev-Rule angewendet (mode 660 root:tss).
  # Marius's user-Service kann dann via TPM auf das Credential zugreifen.
  #
  # Verwandt: Plan-0014, hm-modules/keepassxc-fp-unlock.nix
  security.tpm2 = {
    enable = true;
    abrmd.enable = false;
  };

  # Firmware updates via fwupd/LVFS — passive watcher for the PENDING HP
  # PD-firmware fix. The ZBook G1a's USB-C PD 3.1 firmware is over-sensitive
  # across the 20V↔28V (SPR↔EPR) boundary: with a 140W EPR charger (e.g. the
  # Anker Prime A2687) it negotiates 28V/140W, fails to HOLD it, and flaps
  # AC-online 1→0 → the laptop drains while plugged in. It's an HP EC/PD
  # firmware bug (reproduces on Windows + Linux; PD negotiation is EC-autonomous
  # so Linux can't fix it directly). The fix vehicle is the TI PD firmware
  # bundled in HP's BIOS capsule (firmware family "X89"). As of 2026-06-04 no
  # ZBook fix is published: installed X89 01.04.05 (2026-01-19) is the LATEST
  # for this model AND a known-bad boot-freeze build; the 01.05.01 fix is
  # EliteBook-X-only; LVFS carries only ≤1.3.0.0 (older than installed) → fwupd
  # offers nothing today and just sits idle. Value: when HP DOES publish the fix
  # to LVFS, `fwupdmgr refresh && fwupdmgr update` becomes a one-command,
  # Windows-free UEFI-capsule flash (Secure Boot is OFF here → no capsule-on-
  # reboot stall). DO NOT flash any BIOS while charging is unstable / battery
  # low (brick risk). Workaround meanwhile: daily-drive the HP 140W charger
  # (verified 0 AC-flips/90s); with the Anker use a NON-EPR cable + lone port to
  # stay in stable 20V/≤100W SPR. Full rationale: shared-claude
  # diego-power-charging-profile memory.
  services.fwupd.enable = true;

  system.stateVersion = "25.11";
}
