{ config, lib, pkgs, ... }:

# Plan-0014 — KeePassXC initial-unlock via TPM2-sealed master-PW
# (Software-only Pfad zu Marius's Goal 3: Fingerabdruck als Alternative
# zum Master-Passwort fuer die *initiale* KeePassXC-Authentifizierung).
#
# Mechanik:
#   1. Marius's Master-PW wird einmalig per `tpm2_create -C primary -i <pw>`
#      an die TPM2-Hardware des HP ZBook gebunden. Der TPM emittiert
#      sealed.pub + sealed.priv. sealed.priv ist mit dem TPM-Primary-Key
#      verschluesselt — ohne den TPM2-Chip dieser Maschine ist die Datei
#      nutzlos.
#   2. Hyprland exec-once startet `keepassxc-fp-unlock` (statt direkt
#      `keepassxc`).
#   3. Der Wrapper:
#        - existieren sealed.{pub,priv}: ruft `tpm2_createprimary` (deterministisch
#          aus der TPM-seed identisch zur Setup-Zeit) + `tpm2_load` + `tpm2_unseal`
#          → Master-PW im stdout-Pipe → `keepassxc --pw-stdin` oeffnet die KDBX.
#        - existiert die Datei nicht: graceful fallback auf normales
#          interaktives keepassxc.
#
# Warum tpm2-tools statt systemd-creds:
#   systemd-creds varlink-service refused per-user encrypt-Anfragen aus
#   Security-Gruenden. tpm2-tools spricht /dev/tpmrm0 direkt via tss-Gruppe
#   (security.tpm2.enable + marius in tss-Gruppe). Funktioniert ohne
#   varlink-IPC. Single-Source-of-Truth fuer crypto = TPM-Hardware.
#
# Sicherheits-Modell:
#   - Disk-stolen Angreifer: hat sealed.pub + sealed.priv, kann aber nicht
#     ohne den TPM2-Chip im ZBook entschluesseln. Selbst wenn Angreifer die
#     gesamte BTRFS-Disk extrahiert: Primary-Key ist TPM-bound, kann nirgendwo
#     anders reproduziert werden → Master-PW bleibt verschlossen → KDBX bleibt
#     verschlossen.
#   - Logged-in marius: kann TPM via tss-Gruppe ansprechen, unseal ist transparent.
#   - Local-root: kann alles. Same threat-model als jede andere Linux-Auth.
#
# Verhaeltnis zu Goal 3:
#   - Marius authentifiziert sich am SDDM-Greeter via Fingerabdruck
#     (Plan-0013 macht den "Place finger" Prompt visible)
#   - SDDM-Login → graphical-session.target → Hyprland-Session
#   - Hyprland exec-once → keepassxc-fp-unlock → TPM-unseal → KeePassXC
#     auto-open mit pre-filled Master-PW
#   - Marius tippt NIE wieder das KeePassXC-Master-PW (nach one-time Setup)
#
# Verwandt:
#   - Plan-0013 (SDDM-Fingerprint sichtbar via qylock onInformationMessage)
#   - Plan-0014 (dieses Modul)
#   - ADR-0006 (KeePassXC als Secret-Service)
#   - ADR-0007 (Fingerprint Biometric Foundation)
#
# One-time Setup-Workflow:
#   1. nixos-rebuild switch (dieses Modul wird aktiviert)
#   2. relog/reboot (marius-Mitgliedschaft in tss-Gruppe greift)
#   3. `kp-fp-setup` ausfuehren (interaktiv — fragt Master-PW ab)
#      → erzeugt ~/.config/keepassxc-fp/sealed.{pub,priv,primary-template}
#   4. Next reboot/relog → KeePassXC auto-unlockt
#
# Reversibility: Modul aus home.nix entfernen + ~/.config/keepassxc-fp/
# loeschen → zurueck zu interaktivem KeePassXC. Master-PW im KDBX
# unveraendert (wir aendern die KDBX nie).
#
# TPM-Failure-Modi:
#   - Kernel/Firmware-Update aendert PCR-State → nicht relevant, weil
#     wir KEINE PCR-Policy nutzen (nur SRK-based sealing)
#   - TPM-Reset/Mainboard-Tausch → sealed.priv nicht mehr unsealable →
#     Wrapper fallback'd auf interactive-mode → Marius tippt PW manuell
#     → muss kp-fp-setup neu laufen lassen

let
  kdbxPath = "/home/marius/Syncthing_lighteningv1.0/Organisatorisches/MRPrivat.kdbx";

  # Wrapper-Script: unseal via tpm2-tools, pipes PW in KeePassXC.
  keepassxc-fp-unlock = pkgs.writeShellScriptBin "keepassxc-fp-unlock" ''
    set -u
    KDBX=${lib.escapeShellArg kdbxPath}
    CRED_DIR="$HOME/.config/keepassxc-fp"
    SEALED_PUB="$CRED_DIR/sealed.pub"
    SEALED_PRIV="$CRED_DIR/sealed.priv"

    # Wenn KeePassXC schon laeuft, zweiter exec-once oder manueller Start
    # — KeePassXC selbst dedupliziert.
    if ${pkgs.procps}/bin/pgrep -x keepassxc >/dev/null 2>&1; then
      exec ${pkgs.keepassxc}/bin/keepassxc "$KDBX"
    fi

    if [ -f "$SEALED_PUB" ] && [ -f "$SEALED_PRIV" ]; then
      # tpm2-unseal pipeline. tmpdir fuer ephemere context-files.
      TMP=$(${pkgs.coreutils}/bin/mktemp -d)
      trap 'rm -rf "$TMP"' EXIT INT TERM

      # Schritt 1: Primary-Key (deterministisch aus TPM-SRK + default template)
      if ! ${pkgs.tpm2-tools}/bin/tpm2_createprimary \
            -C o -c "$TMP/primary.ctx" -Q 2>/dev/null; then
        ${pkgs.coreutils}/bin/printf 'keepassxc-fp-unlock: tpm2_createprimary failed, falling back to interactive\n' >&2
        exec ${pkgs.keepassxc}/bin/keepassxc "$KDBX"
      fi

      # Schritt 2: sealed object laden
      if ! ${pkgs.tpm2-tools}/bin/tpm2_load \
            -C "$TMP/primary.ctx" \
            -u "$SEALED_PUB" -r "$SEALED_PRIV" \
            -c "$TMP/sealed.ctx" -Q 2>/dev/null; then
        ${pkgs.coreutils}/bin/printf 'keepassxc-fp-unlock: tpm2_load failed (TPM-state geaendert?), falling back\n' >&2
        exec ${pkgs.keepassxc}/bin/keepassxc "$KDBX"
      fi

      # Schritt 3: unseal — PW landet im stdout-Pipe
      if pw=$(${pkgs.tpm2-tools}/bin/tpm2_unseal -c "$TMP/sealed.ctx" 2>/dev/null); then
        ${pkgs.coreutils}/bin/printf '%s' "$pw" \
          | ${pkgs.keepassxc}/bin/keepassxc --pw-stdin "$KDBX" &
        disown
        # Kurz warten damit der Pipe vollstaendig durchgeht bevor unser
        # Shell-Prozess exitet
        sleep 0.5
        # Cleanup happens via trap
        exit 0
      fi
      ${pkgs.coreutils}/bin/printf 'keepassxc-fp-unlock: tpm2_unseal failed, falling back\n' >&2
    fi

    # Fallback: kein sealed-bundle ODER unseal-fail. Normales KeePassXC
    # mit interactive PW-Prompt (= status quo, kein UX-Regress).
    exec ${pkgs.keepassxc}/bin/keepassxc "$KDBX"
  '';

  # Setup-Script: nimmt Master-PW interaktiv, seal via TPM2.
  kp-fp-setup = pkgs.writeShellScriptBin "kp-fp-setup" ''
    set -eu

    CRED_DIR="$HOME/.config/keepassxc-fp"
    SEALED_PUB="$CRED_DIR/sealed.pub"
    SEALED_PRIV="$CRED_DIR/sealed.priv"

    echo "═══════════════════════════════════════════════════════════"
    echo "  KeePassXC Master-PW → TPM2-Sealing Setup (Plan-0014)"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    echo "Dieses Script verschluesselt dein KeePassXC-Master-PW mit"
    echo "dem TPM2-Chip im HP ZBook. Danach oeffnet KeePassXC bei"
    echo "jedem Login automatisch — kein PW-Tippen mehr."
    echo ""

    # TPM-Group-Check
    if ! id -nG | tr ' ' '\n' | grep -q '^tss$'; then
      echo "FAIL: $USER ist nicht in der 'tss'-Gruppe." >&2
      echo "      security.tpm2.enable=true in default.nix?" >&2
      echo "      → nixos-rebuild switch + reboot/relog noetig." >&2
      exit 1
    fi
    echo "✓ Du bist in der tss-Gruppe (TPM-Zugriff OK)"

    # TPM-Device-Check
    if [ ! -r /dev/tpmrm0 ]; then
      echo "FAIL: /dev/tpmrm0 nicht lesbar." >&2
      ls -la /dev/tpmrm0 >&2 || true
      exit 1
    fi
    echo "✓ /dev/tpmrm0 lesbar"

    # Bestaehende sealed-Files?
    ${pkgs.coreutils}/bin/mkdir -p "$CRED_DIR"
    ${pkgs.coreutils}/bin/chmod 700 "$CRED_DIR"
    if [ -f "$SEALED_PUB" ] || [ -f "$SEALED_PRIV" ]; then
      echo ""
      echo "WARN: $CRED_DIR enthaelt bereits sealed-files."
      ${pkgs.coreutils}/bin/printf "Ueberschreiben? [y/N] "
      read -r confirm
      if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "Abbruch — sealed-files bleiben unveraendert."
        exit 0
      fi
    fi

    # Master-PW abfragen
    echo ""
    ${pkgs.coreutils}/bin/printf "KeePassXC Master-PW eingeben (echo aus): "
    stty -echo
    read -r master_pw
    stty echo
    echo ""
    ${pkgs.coreutils}/bin/printf "Master-PW WIEDERHOLEN: "
    stty -echo
    read -r master_pw2
    stty echo
    echo ""

    if [ "$master_pw" != "$master_pw2" ]; then
      echo "FAIL: PW-Eingaben stimmen nicht ueberein." >&2
      unset master_pw master_pw2
      exit 1
    fi
    if [ -z "$master_pw" ]; then
      echo "FAIL: Leeres PW." >&2
      exit 1
    fi
    echo "✓ PW-Eingabe bestaetigt"
    echo ""

    # Sealing-Pipeline
    TMP=$(${pkgs.coreutils}/bin/mktemp -d)
    trap 'rm -rf "$TMP"; unset master_pw master_pw2' EXIT INT TERM

    echo "Seal pipeline:"

    echo -n "  1. tpm2_createprimary (SRK)... "
    if ${pkgs.tpm2-tools}/bin/tpm2_createprimary -C o -c "$TMP/primary.ctx" -Q 2>&1; then
      echo "OK"
    else
      echo "FAIL"
      exit 1
    fi

    echo -n "  2. tpm2_create (seal master-PW)... "
    if ${pkgs.coreutils}/bin/printf '%s' "$master_pw" \
        | ${pkgs.tpm2-tools}/bin/tpm2_create \
          -C "$TMP/primary.ctx" \
          -u "$TMP/sealed.pub" \
          -r "$TMP/sealed.priv" \
          -i - \
          -Q 2>&1; then
      echo "OK"
    else
      echo "FAIL"
      exit 1
    fi

    # Atomar in Cred-Dir verschieben
    ${pkgs.coreutils}/bin/install -m 600 "$TMP/sealed.pub" "$SEALED_PUB"
    ${pkgs.coreutils}/bin/install -m 600 "$TMP/sealed.priv" "$SEALED_PRIV"
    echo "✓ Sealed-files geschrieben: $CRED_DIR/sealed.{pub,priv}"
    echo ""

    # Cleanup PW aus memory
    unset master_pw master_pw2

    # Self-Test: kompletter unseal-cycle
    echo "Self-Test (kompletter unseal-cycle):"
    if ${pkgs.tpm2-tools}/bin/tpm2_createprimary -C o -c "$TMP/p2.ctx" -Q 2>/dev/null && \
       ${pkgs.tpm2-tools}/bin/tpm2_load -C "$TMP/p2.ctx" \
         -u "$SEALED_PUB" -r "$SEALED_PRIV" \
         -c "$TMP/s2.ctx" -Q 2>/dev/null && \
       unsealed=$(${pkgs.tpm2-tools}/bin/tpm2_unseal -c "$TMP/s2.ctx" 2>/dev/null); then
      if [ -n "$unsealed" ]; then
        echo "  ✓ unseal returned non-empty value ($(${pkgs.coreutils}/bin/printf '%s' "$unsealed" | ${pkgs.coreutils}/bin/wc -c) bytes)"
      else
        echo "  ✗ unseal returned EMPTY string"
        exit 1
      fi
      unset unsealed
    else
      echo "  ✗ Self-Test fehlgeschlagen"
      exit 1
    fi

    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "Setup erfolgreich. Test jetzt:"
    echo ""
    echo "  pkill keepassxc; keepassxc-fp-unlock &"
    echo ""
    echo "KeePassXC sollte automatisch oeffnen, OHNE PW-Prompt."
    echo ""
    echo "Nach naechstem Reboot/Login: Plan-0014 ist aktiv."
    echo "═══════════════════════════════════════════════════════════"
  '';
in
{
  home.packages = [
    keepassxc-fp-unlock
    kp-fp-setup
  ];
}
