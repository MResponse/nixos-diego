# Plan-0006 F3b — KeePassXC develop snapshot fuer Polkit Quick Unlock.
#
# Override `pkgs.keepassxc` direkt (kein rename) damit HM-keepmenu.nix
# UND system gleichermassen den snapshot bekommen — sonst koennten zwei
# Binaries in PATH konkurrieren.
#
# 2.8.0 ist unreleased (Milestone 30%, no due date).
# develop hat PR #8983 "Polkit Quick Unlock" gemerged.
#
# Pin: barsikus007's verified-working snapshot (sein config-commit
# e46bf6f6 "keepassxc update"). Diese rev ist Qt5-kompatibel — newer
# develop-HEAD (2026-05-17 0d69edd...) migrierte auf Qt6 namespace was
# nixpkgs's libsForQt5-based derivation nicht ohne grosse Rework bauen
# kann. Polkit-Quick-Unlock-PR (#8983) ist VOR diesem commit gemerged.
#
# Watch-Mechanismus fuer Plan-0007-Migration (overlay-removal wenn
# nixpkgs 2.8.0 ships):
#   - Repology RSS: https://repology.org/project/keepassxc/versions.atom
#   - r-ryantm-PR: https://github.com/NixOS/nixpkgs/pulls?q=is:pr+author:r-ryantm+keepassxc
#   - Habitica monthly task
#
# Issue #12418 (KeePassXC's "Polkit fingerprint unlock on NixOS") wurde
# closed-as-not-planned — kein upstream-Support fuer NixOS-Quirks.

final: prev: {
  keepassxc = (prev.keepassxc.override {
    # Disable SSH-Agent: barsikus007's snapshot (967dc59) baut
    # OpenSSHKeyGen.cpp gegen botan2-API ("EC_Group has incomplete
    # type"). botan2 ist EOL in nixpkgs entfernt. SSH-agent ist
    # optional fuer Marius's use-case (Secret Service + Polkit
    # Quick Unlock unbeeinflusst).
    withKeePassSSHAgent = false;
  }).overrideAttrs (old: {
    version = "2.8.0-snapshot-967dc59";
    src = prev.fetchFromGitHub {
      owner = "keepassxreboot";
      repo  = "keepassxc";
      rev   = "967dc5937f1f69e601f7aecbc600ef9027cc5043";
      sha256 = "sha256-Nfp5B8OZ3NIZIHkR/aVwdnose61gPVEEFsRjEyUm7uw=";
    };
    # Keine zusaetzlichen cmakeFlags noetig — nixpkgs's existierender
    # cmakeFlags-Block (FDOSECRETS=true, YUBIKEY=true, etc.) deckt das
    # ab. withKeePassSSHAgent=false (oben in override) disabled SSH.
    buildInputs = (old.buildInputs or [ ]) ++ [
      prev.keyutils  # libkeyutils — required fuer kernel-keyring storage
                     # des unlocked-DB-keys (Polkit-Quick-Unlock-Mechanik)
    ];
  });
}
