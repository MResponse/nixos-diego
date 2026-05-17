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
    ./gaming.nix
    ./hardware.nix
    ./services.nix
    ./security.nix
    ./power-modes.nix
  ];

  # Five-mode power management replicating HP's Windows myHP modes
  # (Smart Sense / Performance / Cool / Quiet / Power Saver) on top of ppd.
  # See ./power-modes.nix and shared-claude/Softwareprojekte/Nixos-Diego/
  # adr/0024-five-mode-power-system.md.
  services.powerModes = {
    enable = true;
    defaultMode = "smart-sense";
  };

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

  # Auto-login marius into the default desktop session (hyprland-uwsm).
  # Without autoLogin, SDDM presents the Maldives greeter and preselects
  # whichever session was last logged into (state.conf [Last] Session), and
  # one accidental Gamescope login stickies that selection — the greeter's
  # session dropdown is the only escape and on this resolution it has been
  # unreliable to operate. Autologin sidesteps the greeter on the happy path:
  # boot → directly into Hyprland. The Jovian session-switching flow remains
  # intact:
  #   - SUPER+G → steamosctl switch-to-game-mode writes
  #     /etc/sddm.conf.d/zzt-steamos-temp-login.conf with
  #     [Autologin] User=marius Session=gamescope-wayland.desktop.
  #     That file is alphabetically later than 00-nixos.conf, so its
  #     [Autologin] Session= wins for the transition → Gamescope.
  #   - "Switch to Desktop" in Steam → steamos-manager removes the temp file
  #     → next SDDM cycle reads only our 00-nixos.conf → autologin back into
  #     hyprland-uwsm.
  # Coupled to `jovian.steam.enable` like the SDDM/defaultSession switches
  # above: without Jovian, Diego falls back to Donvini's GDM-into-Hyprland
  # default with no autologin.
  services.displayManager.autoLogin = lib.mkIf config.jovian.steam.enable {
    enable = true;
    user = "marius";
  };

  # Defensive boot-time cleanup. If a previous switch-to-game-mode left
  # /etc/sddm.conf.d/zzt-steamos-temp-login.conf behind (steamos-manager
  # crash, hard-power-off mid-transition, daemon order issue at shutdown),
  # SDDM would keep autologging the user into Gamescope on every subsequent
  # boot — exactly the trap Marius hit before this fix landed. Wipe the
  # override at boot only (multi-user.target wantedBy + RemainAfterExit), so
  # an SDDM restart triggered by a *new* in-session switch-to-game-mode does
  # NOT also wipe the freshly-written file. Ordered before display-manager
  # so SDDM sees the cleaned state when it starts.
  systemd.services.diego-sddm-wipe-stale-gamescope-login =
    lib.mkIf config.jovian.steam.enable {
      description = "Wipe stale steamos-manager temp-login override at boot";
      before = [ "display-manager.service" ];
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
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
  #   - sddm: greeter — eliminates the perceived-mandatory prompt at boot
  #     (with autoLogin below the greeter is bypassed entirely on the happy
  #     path, but if autologin ever fails or the user lands on the greeter
  #     manually, the prompt is password-only).
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
    "polkit-1".fprintAuth = lib.mkForce false;
    sudo.fprintAuth = true;
  };

  # Move pam_fprintd AFTER pam_unix on sudo (the only retained surface).
  # Relative offset per NixOS pam.nix docs — absolute order values are
  # subject to nixpkgs renumbering. sddm/login overrides removed: they were
  # reordering a rule that no longer exists in the rendered stack.
  security.pam.services.sudo.rules.auth.fprintd.order =
    config.security.pam.services.sudo.rules.auth.unix.order + 10;

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
