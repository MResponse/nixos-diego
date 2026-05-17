{ pkgs, lib, config, inputs, ... }:

{
  imports = [
    ./packages.nix
    ./fonts.nix
    ./hyprland/default.nix
    ./programming.nix
    ./services.nix
  ];

  security = {
    pam.services.swaylock = { };
    pam.services.login.enableKwallet = true;
  };

  networking.stevenBlackHosts = {
    enable = true;
    blockFakenews = true;
    blockGambling = true;
    blockSocial = true;
  };

  # blockSocial sinkholes web.whatsapp.com (Meta property), which Marius uses
  # as a primary messenger — symptom is a white Electron window. Carve real
  # WhatsApp domains out of the list; phishing lookalikes like
  # whatsapp-app.com stay blocked because they don't match these patterns.
  networking.extraHosts = lib.mkForce (
    let
      raw = builtins.readFile "${inputs.hosts}/alternates/fakenews-gambling-social/hosts";
      isRealWhatsapp = line:
        builtins.match ".*[ \t]([a-z0-9-]+\\.)*whatsapp\\.(com|net)" line != null
        || builtins.match ".*[ \t]whatsapp-cdn-[a-z0-9.-]+\\.fbcdn\\.net" line != null;
      kept = builtins.filter (l: ! isRealWhatsapp l) (lib.splitString "\n" raw);
      ipv4 = lib.concatStringsSep "\n" kept;
      ipv6 = builtins.replaceStrings [ "0.0.0.0" ] [ "::" ] ipv4;
    in
    ipv4 + (lib.optionalString config.networking.enableIPv6 ("\n" + ipv6))
  );

  environment.systemPackages = with pkgs; [
    xhost
    blueman
    brightnessctl
    pinentry-curses
    pinentry-rofi
    libsForQt5.qt5ct
    qt6Packages.qt6ct
    nwg-look
    gparted
    pavucontrol
    filezilla
    linux-firmware
    mtpfs
    wofi-pass
    powertop
    picard
  ];
}
