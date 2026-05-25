# modules/hostname-safety.nix
#
# Plan-0015 / ADR-0035 — Cross-Host-Switch-Prevention.
#
# Zwei orthogonale Bremsen gegen "rebuild auf der falschen Maschine":
#
# 1) Eval-Time assertion: faengt Build-Time-Inkonsistenz ab, wenn
#    networking.hostName im Host-Modul vom Flake-Output-Namen abweicht
#    (z.B. nach versehentlichem Refactor). Vergleicht `expectedHostname`
#    (Factory-injected specialArg) mit `config.networking.hostName`
#    (Modul-system-merged value).
#
# 2) Activation-Time guard: `system.preSwitchChecks.crossHostGuard`
#    laeuft VOR Bootloader-Install und VOR Profile-Pointer-Update
#    (switch-to-configuration-ng main.rs:1690, vor :1701). Vergleicht
#    Kernel-Hostname (Maschinen-Identitaet, kernel-resident bis zum
#    naechsten Reboot) mit der zu aktivierenden Config. Bei Mismatch:
#    Exit 78, /run/current-system + Bootloader + Profile bleiben
#    100% unveraendert. Laeuft NICHT beim Boot (Stage-2-Init ruft
#    nur `activate`, nicht `pre-switch-check`) → Guard-Bug kann
#    Maschine nicht bricken.
#
# Escape-Hatch: Sentinel-File `/etc/.nix-allow-cross-host-switch`.
# Single-shot — wird nach Verbrauch sofort geloescht.
#
# Verifiziert gegen nixpkgs rev f8573b9c93 (NixOS 26.05):
# - Option-Def: nixos/modules/system/activation/pre-switch-check.nix:33-54
# - Doc-String live geprueft via `nix eval` am 2026-05-25.

{ config, lib, expectedHostname, ... }:

{
  assertions = [
    {
      assertion = config.networking.hostName == expectedHostname;
      message = ''
        Hostname-Identity Mismatch:
          Factory expects (flake output name): "${expectedHostname}"
          Config sets networking.hostName:     "${config.networking.hostName}"

        Diese Werte muessen identisch sein. Mismatch bedeutet entweder:
        (a) hosts/${expectedHostname}/default.nix setzt einen falschen
            networking.hostName — Tippfehler korrigieren.
        (b) Ein importierter Module ueberschreibt networking.hostName
            mit lib.mkForce — Override entfernen oder Modul anpassen.
      '';
    }
  ];

  # Snippet-Name absichtlich generisch (nicht "diegoCrossHostGuard"),
  # damit das Modul fuer alle Hosts (dracula + nixos-diego + alucard)
  # sauber passt — alle drei importieren diese Datei via
  # mkDesktopHost/mkServerHost in flake.nix.
  system.preSwitchChecks.crossHostGuard = ''
    set -eu

    # switch-to-configuration ruft pre-switch-check mit zwei Args auf:
    # $1 = neuer toplevel-Pfad, $2 = action (switch/boot/test/dry-activate).
    new_system="''${1:-}"
    action="''${2:-}"

    # 1) Fresh-Install-Bypass: bei der allerersten Installation gibt es
    #    /run/current-system nicht. Dann gibt es auch keine alte Identitaet,
    #    die wir schuetzen muessten. Pattern uebernommen aus nix-community/srvos.
    [ -e /run/current-system ] || exit 0

    # 2) Nur fuer Actions die wirklich aktivieren — `build`, `dry-build`
    #    etc. haben leere action und sollen nicht blockieren.
    case "$action" in
      switch|boot|test|dry-activate) ;;
      *) exit 0 ;;
    esac

    actual=$(cat /proc/sys/kernel/hostname 2>/dev/null || echo "")
    expected="${config.networking.hostName}"
    sentinel=/etc/.nix-allow-cross-host-switch

    # 3) Defensive fail-open: kein Kernel-Hostname lesbar → nicht
    #    blockieren. Lieber selten "Schutz ausgesetzt" als haeufig
    #    "Maschine gebrickt".
    [ -n "$actual" ] || exit 0

    # 4) Match → alles gut.
    if [ "$actual" = "$expected" ]; then
      exit 0
    fi

    # 5) Sentinel vorhanden → ein einziger Cross-Host-Switch erlaubt.
    #    Datei wird sofort geloescht (single-shot). Idempotent gegen Re-run.
    if [ -f "$sentinel" ]; then
      rm -f "$sentinel"
      echo "[cross-host-guard] Sentinel consumed; cross-host switch authorized." >&2
      exit 0
    fi

    # 6) Default: refuse mit klarer Diagnose und Exit 78 (EX_CONFIG).
    cat >&2 <<EOF

    ==================================================================
     REFUSING TO SWITCH: cross-host configuration detected
    ==================================================================
     This machine boots as:       $actual
     Configuration being applied: $expected

     You probably ran:
       sudo nixos-rebuild $action --flake .#$expected
     but you meant:
       sudo nixos-rebuild $action --flake .#$actual

     To override (DANGER — replaces this machine's identity):
       sudo touch $sentinel
       sudo nixos-rebuild $action --flake .#$expected
    ==================================================================
    EOF
    exit 78
  '';
}
