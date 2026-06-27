# Geekbench 6.7.1 — fixes the Linux result-UPLOAD failure "unknown error
# (internal code 35)".
#
# SYMPTOM (with nixpkgs' pinned geekbench 6.4.0):
#   The CPU benchmark runs fine, but uploading the result to the Geekbench
#   Browser dies with `unknown error (internal code 35)` (= libcurl
#   CURLE_SSL_CONNECT_ERROR, a TLS-handshake failure). The free edition FORCES
#   an upload to produce a result, so a failed upload = no result link at all.
#
# ROOT CAUSE (Primate Labs, official — geekbench.com/blog/2026/04/geekbench-671):
#   Geekbench 6 for Linux/Android STATICALLY BUNDLES its own LibreSSL. Maxon put
#   Cloudflare in front of the Geekbench Browser; the OUTDATED bundled LibreSSL
#   can no longer complete the TLS handshake to Cloudflare's edge → upload fails.
#   Windows/macOS/iOS use the platform SSL stack and are unaffected (a MacBook
#   M5 on the same network uploads fine). Verified locally that this is NOT a
#   NixOS CA problem: running 6.4.0 with SSL_CERT_FILE *and* CURL_CA_BUNDLE set
#   STILL failed with internal code 35 — the bundled LibreSSL ignores them.
#
# FIX:
#   Geekbench 6.7.1 (2026-04-28) updates the bundled LibreSSL. Changelog
#   verbatim: "Fix Geekbench Browser connection errors on Android and Linux."
#   Empirically confirmed on this exact ZBook: 6.7.1 uploads successfully
#   (browser.geekbench.com/v6/cpu/18415829).
#
# WHY an overrideAttrs and not a flake input:
#   nixpkgs' geekbench is just a fetchurl repackage of the upstream prebuilt
#   tarball (autoPatchelfHook + wrapProgram that only sets LD_LIBRARY_PATH), and
#   that logic is unchanged between 6.4.0 and 6.7.1 — so bumping version + src is
#   sufficient. Overriding `pkgs.geekbench` in place (no rename) keeps the single
#   reference at hm-modules/packages.nix:86 working and avoids a second
#   nixpkgs-unstable input (extra flake.lock churn on this multi-device branch).
#   No SSL_CERT_FILE/CURL_CA_BUNDLE wrapping is added — it is not the cause and
#   does not help; the cure lives inside the 6.7.1 tarball's LibreSSL.
#
# WATCH-MECHANISM (remove this overlay once nixpkgs ships >= 6.7.1):
#   nixpkgs-unstable already has 6.7.1; stable lags (25.05 = 6.4.0). Track:
#     https://www.primatelabs.com/release/geekbench6/
#   Bump `version`, refresh `hash`:
#     nix-prefetch-url --type sha256 \
#       https://cdn.geekbench.com/Geekbench-<ver>-Linux.tar.gz \
#       | xargs nix hash to-sri --type sha256
#   The hash below is independently corroborated by the Flathub manifest
#   (com.geekbench.Geekbench6: sha256
#   0ddca977deb6d9db4bd866485f9408e72e2869d0dea0737b18d4bfe472858ace).
final: prev: {
  geekbench = prev.geekbench.overrideAttrs (old: rec {
    version = "6.7.1";
    src = prev.fetchurl {
      url = "https://cdn.geekbench.com/Geekbench-${version}-Linux.tar.gz";
      hash = "sha256-Ddypd9622dtL2GZIX5QI5y4oadDeoHN7GNS/5HKFis4=";
    };
  });
}
