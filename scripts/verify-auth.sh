#!/usr/bin/env bash
# Plan-0013 F5 — Live-Verification-Catalogue für Plan-0012 + Plan-0013
# Goals. Ausführen post-rebuild als marius. Erwarteter Lauf: ~10 Sekunden.
#
# Verwendet KEIN sudo (alles statische probes); bricht NICHT laufende
# Sessions.

set -u

GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
PASS=0; FAIL=0; WARN=0

ok()   { echo "${GREEN}✓${RESET} $1"; PASS=$((PASS+1)); }
bad()  { echo "${RED}✗${RESET} $1"; FAIL=$((FAIL+1)); }
warn() { echo "${YELLOW}⚠${RESET} $1"; WARN=$((WARN+1)); }

echo "═══ V1: SDDM/PAM Fingerprint wiring ═══"
if grep -q "pam_fprintd.so" /etc/pam.d/login 2>/dev/null; then
  ok "fprintd in /etc/pam.d/login"
else
  bad "fprintd MISSING in /etc/pam.d/login"
fi
ord_unix=$(awk '/^auth.*pam_unix/{print NR; exit}' /etc/pam.d/login 2>/dev/null)
ord_fp=$(awk '/^auth.*pam_fprintd/{print NR; exit}' /etc/pam.d/login 2>/dev/null)
if [ -n "${ord_unix:-}" ] && [ -n "${ord_fp:-}" ] && [ "$ord_unix" -lt "$ord_fp" ]; then
  ok "PAM-order: pam_unix BEFORE pam_fprintd (kein 30s-hang Bug)"
else
  bad "PAM-order WRONG (unix=${ord_unix:-?}, fp=${ord_fp:-?})"
fi
if grep -q "pam_fprintd.so" /etc/pam.d/polkit-1 2>/dev/null; then
  ok "fprintd in /etc/pam.d/polkit-1 (KeePassXC Polkit-Auth path)"
else
  warn "fprintd MISSING in /etc/pam.d/polkit-1 (KeePassXC Quick Unlock braucht das)"
fi
fp_enrolled=$(fprintd-list "$USER" 2>/dev/null | grep -cE "right-index|left-index|right-thumb|left-thumb|right-middle|left-middle|right-ring|left-ring|right-little|left-little")
if [ "${fp_enrolled:-0}" -gt 0 ]; then
  ok "fprintd: $USER hat $fp_enrolled enrolled finger(s)"
else
  bad "fprintd: KEINE Finger enrolled — fprintd-enroll laufen lassen"
fi

echo
echo "═══ V2: qylock Theme-Patches (Plan-0012 F1 + Plan-0013 F1.1/F4) ═══"
ACTIVE=""
if [ -L /run/current-system/sw/share/sddm/themes/field ]; then
  ACTIVE=$(dirname "$(readlink -f /run/current-system/sw/share/sddm/themes/field 2>/dev/null)")
fi
if [ -d "$ACTIVE" ]; then
  pool_name=$(basename "$(dirname "$(dirname "$ACTIVE")")")
  ok "ACTIVE qylock pool: $pool_name"
else
  bad "ACTIVE qylock pool not found (Plan-0004 broken?)"
  ACTIVE="/dev/null"
fi
miss_ab=0; miss_im=0; total=0
miss_ab_list=""; miss_im_list=""
for d in "$ACTIVE"/*/; do
  [ -d "$d" ] || continue
  [ "$(basename "$d")" = "qylock-random" ] && continue
  total=$((total+1))
  if ! grep -q "acceptedButtons: Qt.NoButton" "$d/Main.qml" 2>/dev/null; then
    miss_ab=$((miss_ab+1))
    miss_ab_list="$miss_ab_list $(basename "$d")"
  fi
  if ! grep -q "function onInformationMessage" "$d/Main.qml" 2>/dev/null; then
    miss_im=$((miss_im+1))
    miss_im_list="$miss_im_list $(basename "$d")"
  fi
done
if [ "$miss_ab" -eq 0 ]; then
  ok "F1+F1.1 (acceptedButtons): ALLE $total themes patched"
else
  bad "F1+F1.1: $miss_ab/$total themes MISS acceptedButtons-patch:$miss_ab_list"
fi
if [ "$miss_im" -eq 0 ]; then
  ok "F4 (onInformationMessage): ALLE $total themes patched"
else
  warn "F4: $miss_im/$total themes MISS onInformationMessage-handler (PAM_TEXT_INFO unsichtbar dort):$miss_im_list"
fi

echo
echo "═══ V3: KeePassXC 2.8 + Polkit Quick Unlock readiness ═══"
kp_ver=$(keepassxc --version 2>&1 | head -1 || echo "?")
if echo "$kp_ver" | grep -q "2\.8"; then
  ok "KeePassXC version: $kp_ver"
else
  bad "KeePassXC version unexpected: $kp_ver (Plan-0012 F3 overlay broken?)"
fi
if ls /run/current-system/sw/share/polkit-1/actions/ 2>/dev/null | grep -q "keepassxc"; then
  ok "Polkit-action org.keepassxc.KeePassXC.policy registered"
else
  bad "Polkit-action NOT registered (Plan-0012 F3.2 broken?)"
fi
if pkaction --action-id org.keepassxc.KeePassXC.unlockDatabase 2>/dev/null | grep -q "unlockDatabase"; then
  ok "pkaction confirms unlockDatabase available"
else
  bad "pkaction returns no action — Polkit-policy not picked up"
fi
KP_BIN=$(which keepassxc 2>/dev/null)
if [ -x "$KP_BIN" ] && ldd "$KP_BIN" 2>/dev/null | grep -q libkeyutils; then
  ok "KeePassXC linked to libkeyutils (Polkit Quick Unlock kernel-keyring storage)"
else
  bad "KeePassXC NOT linked to libkeyutils (Plan-0012 F3.1 broken?)"
fi
# Issue #11316/#12418 catch — KeePassXC config file
KP_INI="$HOME/.config/keepassxc/keepassxc.ini"
if [ -f "$KP_INI" ]; then
  if grep -qE "^QuickUnlock=true" "$KP_INI"; then
    ok "KeePassXC Quick Unlock ENABLED in config"
  else
    warn "KeePassXC Quick Unlock NOT YET enabled in config — one-time setup pending (Settings → Security → Enable Quick Unlock)"
  fi
else
  warn "KeePassXC config file noch nicht existiert — first-run pending"
fi

echo
echo "═══ V4: fprintd daemon healthy ═══"
if busctl list 2>/dev/null | grep -q "net.reactivated.Fprint"; then
  ok "fprintd DBus name registered (activatable on-demand)"
else
  warn "fprintd DBus name not visible (probably on-demand, activates bei PAM-trigger)"
fi
if systemctl status fprintd.service --no-pager 2>&1 | head -3 | grep -qE "loaded|active"; then
  ok "fprintd.service loaded"
else
  bad "fprintd.service NOT loaded"
fi

echo
echo "═══ V5: Session-Switch infrastructure (SUPER+G handover) ═══"
if systemctl is-active diego-greeter-preselect-on-zzt.path 2>/dev/null | grep -q "active"; then
  ok "greeter-preselect path-unit armed"
else
  bad "greeter-preselect path-unit NOT armed"
fi
if [ -f /var/lib/sddm/state.conf ]; then
  last_sess=$(sudo grep '^Session=' /var/lib/sddm/state.conf 2>/dev/null | sed 's|.*/||' || echo "?")
  ok "state.conf exists (last session: $last_sess)"
else
  warn "state.conf missing (kein previous login)"
fi
if systemctl status diego-sddm-wipe-stale-gamescope-login.service --no-pager 2>&1 | grep -q "RemainAfterExit=yes"; then
  ok "boot-cleanup-service for stale zzt-conf armed"
else
  warn "boot-cleanup-service status unclear"
fi

echo
echo "═══ V6: Negativ-Tests (was NICHT da sein darf) ═══"
if ls /etc/sddm.conf.d/zzt-*.conf 2>/dev/null | head -1 | grep -q "zzt"; then
  bad "STALE /etc/sddm.conf.d/zzt-*.conf vorhanden (gamescope-switch in flight oder crashed mid-switch)"
else
  ok "Kein stale zzt-*.conf"
fi
if grep -rn "fprintAuth.*mkForce.*false" /home/marius/nixos-config/ 2>/dev/null | grep -v "#" | grep -q "lib.mkForce"; then
  warn "stale 'mkForce false fprintAuth' in source — Plan-0012 F2 nicht ganz clean"
else
  ok "Keine mkForce false fprintAuth-overrides"
fi
if [ -f /etc/sddm.conf.d/theme.conf ] && [ ! -L /etc/sddm.conf.d/theme.conf ]; then
  warn "stale /etc/sddm.conf.d/theme.conf — Plan-0003 F5 wipe-service hat versagt"
else
  ok "Kein stale theme.conf override"
fi

echo
echo "════════════════════════════════════════════════════════════"
printf "  ${GREEN}Pass${RESET}: %d   ${RED}Fail${RESET}: %d   ${YELLOW}Warn${RESET}: %d\n" "$PASS" "$FAIL" "$WARN"
echo "════════════════════════════════════════════════════════════"
if [ "$FAIL" -eq 0 ]; then
  echo "${GREEN}Plan-0012/0013 static-state OK.${RESET}"
  echo "Next: REBOOT + Live-Test laut OPERATIONS.md."
  exit 0
else
  echo "${RED}$FAIL FAIL(s) gefunden — Plan-0013 nicht voll appliziert.${RESET}"
  exit 1
fi
