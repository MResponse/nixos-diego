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

  # blockSocial sinkholes Meta + Reddit properties that Marius actually uses.
  # WhatsApp: web.whatsapp.com used as primary messenger → white Electron window
  # when blocked. Reddit: *.reddit.com used for browsing. Carve both back in;
  # phishing lookalikes (whatsapp-app.com, reddit-app.io, …) stay blocked since
  # they don't match these conservative patterns.
  networking.extraHosts = lib.mkForce (
    let
      raw = builtins.readFile "${inputs.hosts}/alternates/fakenews-gambling-social/hosts";
      isAllowlisted = line:
        # WhatsApp / Meta CDN
        builtins.match ".*[ \t]([a-z0-9-]+\\.)*whatsapp\\.(com|net)" line != null
        || builtins.match ".*[ \t]whatsapp-cdn-[a-z0-9.-]+\\.fbcdn\\.net" line != null
        # Reddit (incl. redditmedia, redditstatic for assets, redd.it shortener)
        || builtins.match ".*[ \t]([a-z0-9-]+\\.)*reddit\\.com" line != null
        || builtins.match ".*[ \t]([a-z0-9-]+\\.)*redditmedia\\.com" line != null
        || builtins.match ".*[ \t]([a-z0-9-]+\\.)*redditstatic\\.com" line != null
        || builtins.match ".*[ \t]([a-z0-9-]+\\.)*redd\\.it" line != null;
      kept = builtins.filter (l: ! isAllowlisted l) (lib.splitString "\n" raw);
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
