{
  config,
  lib,
  pkgs,
  username,
  inputs,
  ...
}:

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
    ./gamescope-power.nix    # Plan-0002 §2.4 — force `performance` while Gamescope is active
  ];

  # Five-mode power management replicating HP's Windows myHP modes
  # (Smart Sense / Performance / Cool / Quiet / Power Saver) on top of ppd.
  # See ./power-modes.nix and shared-claude/Softwareprojekte/Nixos-Diego/
  # adr/0024-five-mode-power-system.md.
  services.powerModes = {
    enable = true;
    defaultMode = "smart-sense";
  };

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
    sddm.fprintAuth = lib.mkForce false;
    login.fprintAuth = lib.mkForce false;
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
    ];
    packages = with pkgs; [ ];
  };

  system.stateVersion = "25.11";
}
