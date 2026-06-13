{ pkgs, ... }:

# Microsoft 365 work-app bundle for the `acrm` user (Tier-1).
#
# SCOPE: acrm-only. Imported solely from home-acrm.nix — NOT from marius's
# home.nix. marius keeps his own teams-for-linux entry in
# hm-modules/packages.nix:119 (intentionally NOT deleted); having Teams in
# both package sets is fine (home-manager installs per-user, no collision).
#
# With home-manager.useUserPackages = true (flake.nix:125) these land in
# /etc/profiles/per-user/acrm ONLY — never on marius's PATH. That is the real
# isolation boundary (home-manager nixos/common.nix:181).
#
# WHY THESE THREE:
#   - microsoft-edge:  the Entra/Conditional-Access-aware browser. acrm signs
#                      Edge into Teams/SharePoint to TEST empirically whether
#                      Conditional Access requires a managed/compliant device.
#                      No broker / no keyring / no services.intune yet
#                      (decided: test first — that's the Tier-2 gate).
#   - teams-for-linux: Teams client (community Electron wrapper).
#   - onedrive:        abraunegg OneDrive client (CLI/daemon). Started manually
#                      by acrm for now; the user systemd service is provided
#                      commented-out below to opt into later.
#
# Pure home.packages — no identity args, no /home paths, no activation
# side-effects. Fully per-user-safe.

{
  home.packages = with pkgs; [
    microsoft-edge
    teams-for-linux
    onedrive
  ];

  # OPTIONAL — enable later, AFTER acrm has run `onedrive` interactively once
  # to authorise the account (the --monitor daemon needs an existing refresh
  # token, else it crash-loops). Uncomment to run OneDrive sync as an acrm
  # user service:
  #
  # systemd.user.services.onedrive = {
  #   Unit = {
  #     Description = "OneDrive sync (acrm)";
  #     After = [ "network-online.target" ];
  #     Wants = [ "network-online.target" ];
  #   };
  #   Service = {
  #     ExecStart = "${pkgs.onedrive}/bin/onedrive --monitor";
  #     Restart = "on-failure";
  #     RestartSec = 30;
  #   };
  #   Install.WantedBy = [ "default.target" ];
  # };
}
