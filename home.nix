{
  inputs,
  pkgs,
  lib,
  username,
  ...
}:

{
  imports = [
    ./hm-modules/git.nix
    ./hm-modules/ssh.nix
    ./hm-modules/fish.nix
    ./hm-modules/shell.nix
    ./hm-modules/helix.nix
    ./hm-modules/hyprland.nix
    ./hm-modules/kitty.nix
    ./hm-modules/mpv.nix
    ./hm-modules/packages.nix
    ./hm-modules/starship.nix
    ./hm-modules/yazi.nix
    ./hm-modules/zathura.nix
    ./hm-modules/doom.nix
    ./hm-modules/zellij.nix
    ./hm-modules/caelestia.nix
    ./hm-modules/services.nix
    ./hm-modules/keepmenu.nix
    ./hm-modules/keepassxc-fp-unlock.nix   # Plan-0014 — TPM2-sealed Master-PW auto-unlock
    ./hm-modules/darkman.nix
    ./hm-modules/gtk.nix
    inputs.caelestia-shell.homeManagerModules.default
  ];

  nixpkgs.config.allowUnfree = true;

  home = {
    username = "${username}";
    homeDirectory = "/home/${username}";
    stateVersion = "23.05";
    pointerCursor = {
      name = "Bibata-Modern-Ice";
      package = pkgs.bibata-cursors;
      size = 24;
      gtk.enable = true;
    };
  };

  fonts.fontconfig.enable = true;
  programs.home-manager.enable = true;

  xdg.mimeApps.defaultApplications = {
    "application/pdf" = [ "zathura.desktop" ];
    "image/*" = [ "viewnior.desktop" ];
    "video/*" = [ "mpv.desktop" ];
    # Plan-0009 S3: SteamVR's vrmonitor URL scheme (used by Developer
    # settings → "Save Frames to Disk" etc.). Without this entry, Gnome
    # shows "No Apps available — No apps installed that can open 'vrmonitor://…'".
    "x-scheme-handler/vrmonitor" = [ "valve-URI-vrmonitor.desktop" ];
  };

  # Plan-0009 S3: install the .desktop file that handles vrmonitor:// URLs.
  # The Exec= path is fixed to the user-installed SteamVR binary; if Steam
  # moves the install, the URL handler stops working (warned by vr-doctor).
  xdg.desktopEntries.valve-URI-vrmonitor = {
    name = "SteamVR URI Handler";
    noDisplay = true;
    exec = "/home/${username}/.local/share/Steam/steamapps/common/SteamVR/bin/linux64/vrmonitor %U";
    mimeType = [ "x-scheme-handler/vrmonitor" ];
  };

  # Plan-0009 S2: Register SteamVR as the host's OpenXR runtime so OpenXR
  # games (Beat Saber, modern Unity-VR, etc.) find it. Imperative activation
  # because the source path is Steam's install dir (not /nix/store) and
  # xdg.configFile.source expects a store path.
  home.activation.openxrSteamVRRuntime = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run mkdir -p /home/${username}/.config/openxr/1
    run ln -sfT \
      /home/${username}/.local/share/Steam/steamapps/common/SteamVR/steamxr_linux64.json \
      /home/${username}/.config/openxr/1/active_runtime.json
  '';

  systemd.user.startServices = "sd-switch";
}
