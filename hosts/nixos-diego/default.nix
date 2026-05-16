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

  # Fingerprint biometric authentication. ZBook Ultra G1a ships with a
  # Synaptics 06cb:0106 reader, supported natively by libfprint's "Synaptics
  # Sensors" driver (no proprietary libfprint-2-tod needed). fprintAuth on
  # each PAM service prepends `auth sufficient pam_fprintd.so`, so fingerprint
  # is tried first and password remains a fallback. Caelestia's lock screen
  # auto-detects enrolled fingerprints via its built-in Pam.qml fprint context
  # (default enableFprint = true), so no per-shell config is needed.
  #
  # `login` (TTY) is intentionally NOT in this set — Marius uses SDDM as the
  # primary login surface; leaving TTY without fprintAuth ensures a stolen
  # finger can't reach an authenticated shell via VT-switch when SDDM is
  # locked. Password remains the fallback at TTY.
  #
  # `polkit-1` is intentionally NOT in this set — CVE-2024-37408 documents
  # that `auth sufficient pam_fprintd.so` on polkit-1 lets a background
  # process hijack the next fingerprint touch to authorize a privileged
  # action without Marius realizing what he's authorizing (CVSS 7.3 HIGH,
  # vendor disputed but the mechanism is real). The polkit GUI dialog IS
  # the only remaining attention-point that confirms "yes, this specific
  # action is what I want". Password-on-polkit is rare enough (a few times
  # a week max) that the UX cost is negligible vs. the security gain.
  # sudo keeps fprintAuth because TTY sudo prints "Place finger on sensor"
  # — Marius sees what he's about to authorize. Different attention model.
  #
  # Master password for KeePassXC stays — Linux has no Touch-ID-equivalent
  # path for KeePassXC's first unlock; the autostart in hm-modules/hyprland.nix
  # plus Quick Unlock keeps it to one master-password entry per boot.
  services.fprintd.enable = true;
  security.pam.services = {
    sddm.fprintAuth = true;
    sudo.fprintAuth = true;
  };

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
