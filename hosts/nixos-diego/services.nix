{ pkgs, ... }:

{
  virtualisation.docker = {
    enable = true;
    autoPrune.enable = true;
  };

  environment.systemPackages = with pkgs; [
    keepassxc
    thunderbird-latest
    # Polkit authentication agent — pops the Qt password dialog when an
    # action (fprintd-enroll, GUI apps requesting root, etc.) needs auth.
    # Donvini's kwallet PAM pulled this in transitively before; with kwallet
    # disabled on Diego (see default.nix), declare it explicitly. Started
    # via Hyprland exec-once in hm-modules/hyprland.nix.
    kdePackages.polkit-kde-agent-1
  ];
}
