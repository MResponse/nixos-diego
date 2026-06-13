{ pkgs, ... }:

{
  programs = {
    steam = {
      enable = true;
      # ADR-0038: CachyOS Proton as a declarative Steam compat tool. Shows up
      # as "Proton-CachyOS" in Steam → Settings → Compatibility. Carries the
      # FSR4 DLL-upgrade path for the 8060S (gfx1151); enable per game with the
      # launch option `PROTON_FSR4_RDNA3_UPGRADE=1 %command%` (RDNA 3.5 uses the
      # RDNA3 path: FP8 emulation + auto wmma_rdna3_workaround). The game must
      # already support FSR 3.1 — the DLL swap upgrades FSR 3.1 → FSR 4.
      # Defined in pkgs/proton-cachyos.nix, wired via the flake overlay.
      extraCompatPackages = [ pkgs.proton-cachyos ];
      gamescopeSession.enable = true;
      remotePlay.openFirewall = true; # Open ports in the firewall for Steam Remote Play
      dedicatedServer.openFirewall = true; # Open ports in the firewall for Source Dedicated Server
      localNetworkGameTransfers.openFirewall = true; # Open ports in the firewall for Steam Local Network Game Transfers

    };
    gamescope.enable = true;
  };
  programs.gamemode = {
    enable = true;
    settings = {
      general = {
        renicer = 10;
        softrealtime = "auto";
        inhibit_screensaver = 1;
      };
    };
  };
  hardware.xone.enable = true; # support for the xbox controller USB dongle
  environment.systemPackages = with pkgs; [
    mangohud
    protonup-ng
    wine-wayland
    winetricks
    wineWow64Packages.full
    mono
  ];

  environment.sessionVariables = {
    STEAM_EXTRA_COMPAT_TOOLS_PATHS = "\${HOME}/.steam/root/compatibilitytools.d";
  };

  services.lsfg-vk = {
    enable = true;
    ui.enable = true; # installs gui for configuring lsfg-vk
  };
}
