{ lib, pkgs, ... }:

# Jovian-NixOS-Security-Hardening — Diego-only.
#
# Jovian's Default-Stack ist auf SteamOS-Verkaufs-Hardware abgestimmt:
# Single-User-`deck`-Account, kein echter Multi-User-Trust-Boundary,
# offene Polkit-Helper für Bequemlichkeit. Auf einem Multi-Purpose-Laptop
# (echte sudo/wheel-Trennung, USB4-DMA-Surface, potentielle Browser-RCE)
# muss diese Permissiveness eingebremst werden.
#
# Konkret behandelt:
#   1. SteamOSManager1-RootManager-DBus: System-Bus-Policy-Override
#      → deny default, allow nur marius + root
#   2. org.valve.policykit.{holo,steamos}-Polkit-Policies (allow_any=yes)
#      → Polkit-Rule die sensible Actions (BIOS/Format/sshd/Factory-Reset)
#        auf marius+active+local mit AUTH_ADMIN_KEEP einschränkt,
#        harmlose Tweaks (fan/amp/session-select) durchlässt
#
# Details: shared-claude/Softwareprojekte/Nixos-Diego/adr/0009-jovian-security-hardening.md

{
  # --- 1. DBus-System-Bus: SteamOSManager1-RootManager auf marius+root limitieren
  #
  # Jovian's mitgelieferte system.d-Policy erlaubt `default` (= alle lokalen User
  # auf dem System-Bus) `send_destination=com.steampowered.SteamOSManager1`.
  # Damit kann jeder Prozess am System-Bus (auch services-User, kompromittierte
  # Helper, Container-User) Methoden auf `RootManager` aufrufen:
  # `SetTdpLimit`, `UpdateBios`, `FormatDevice`, `PrepareFactoryReset`, …
  # Alle ohne Polkit-Check oder caller_uid-Filter (verifiziert in
  # steamos-manager/src/manager/root.rs:138-980).
  #
  # Override packt ein Late-Loading-Policy-File nach
  # /etc/dbus-1/system.d/, das deny default + explicit allow für marius + root
  # setzt. DBus mergt alle Policies in alphabetischer Reihenfolge —
  # `zz-steamos-manager-restrict.conf` läuft als letztes und gewinnt.
  services.dbus.packages = [
    (pkgs.writeTextFile {
      name = "steamos-manager-dbus-restrict";
      destination = "/share/dbus-1/system.d/zz-steamos-manager-restrict.conf";
      text = ''
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE busconfig PUBLIC
         "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
         "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
        <busconfig>
          <policy context="default">
            <deny send_destination="com.steampowered.SteamOSManager1"/>
            <deny send_destination="com.steampowered.SteamOSManager1.RootManager"/>
          </policy>
          <policy user="marius">
            <allow send_destination="com.steampowered.SteamOSManager1"/>
            <allow send_destination="com.steampowered.SteamOSManager1.RootManager"/>
          </policy>
          <policy user="root">
            <allow send_destination="com.steampowered.SteamOSManager1"/>
            <allow send_destination="com.steampowered.SteamOSManager1.RootManager"/>
          </policy>
        </busconfig>
      '';
    })
  ];

  # --- 2. Polkit: SteamOS-/Holo-Helper-Policies narrow auf marius+active+local
  #
  # holo-polkit-helpers + steamos-polkit-helpers liefern Policies mit
  # allow_any=yes + allow_inactive=yes + allow_active=yes für 34 Actions —
  # designed für Steam-Deck's Single-User-Modell, falsch für Diego.
  #
  # Sensible Actions (BIOS/Format/Factory-Reset/sshd/priv-write): AUTH_ADMIN_KEEP
  # → Polkit-Dialog mit Auth-Confirmation, 5min Keep.
  # Harmlose Tweaks (fan/amp/session-select/check-support): YES für marius+active.
  # Alle anderen User: NO.
  #
  # Wirkt zusätzlich zur bestehenden fprint-enroll-Rule in default.nix
  # (security.polkit.extraConfig merget Strings konkateniert).
  security.polkit.extraConfig = ''

    // Diego — Jovian-Security-Hardening (ADR-0009)
    // Override Jovian's wide-open SteamOS-Deck-Polkit-Defaults
    polkit.addRule(function(action, subject) {
      var actId = action.id;

      var isHolo = actId.indexOf("org.valve.policykit.holo") == 0;
      var isSteamOS = actId.indexOf("org.valve.policykit.steamos") == 0;

      if (!isHolo && !isSteamOS) {
        return;  // anderen Actions nicht anfassen
      }

      // Nicht-marius oder nicht-active/local: hart verweigern
      if (subject.user != "marius" || !subject.local || !subject.active) {
        return polkit.Result.NO;
      }

      // Sensible Actions: explizite Auth-Confirmation (Polkit-Dialog),
      // Keep für 5min damit nicht jeder Klick einzeln auth-t.
      var sensitiveActions = [
        "biosupdate",
        "dock-updater",
        "initial-firmware-update",
        "format-device",
        "format-sdcard",
        "trim-devices",
        "factory-reset",
        "enable-sshd",
        "priv-write",
        "devkit-mode",
        "set-hostname",
        "set-timezone",
        "select-branch",
      ];
      for (var i = 0; i < sensitiveActions.length; i++) {
        if (actId.indexOf(sensitiveActions[i]) >= 0) {
          return polkit.Result.AUTH_ADMIN_KEEP;
        }
      }

      // Harmlose Performance-/Power-Tweaks während Gaming: silently allow
      // (fan-control, amp-control, session-select, disable-wireless-power-mgmt,
      // get-als-gain, check-support, restart-sddm)
      return polkit.Result.YES;
    });

    // Jovian's modules/steam/steam.nix:150 öffnet NetworkManager-Policies
    // für alle User in der `users`-Gruppe. Auf Diego ist Marius schon in
    // `networkmanager`-Group — explizite Rule für nicht-NM-Group-User:
    polkit.addRule(function(action, subject) {
      if (action.id.indexOf("org.freedesktop.NetworkManager") == 0 &&
          !subject.isInGroup("networkmanager")) {
        return polkit.Result.AUTH_ADMIN;
      }
    });
  '';
}
