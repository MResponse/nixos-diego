{ config, ... }:

# Warp Terminal — Marius's keybindings (pane navigation alt-wasd, font size).
#
# Source of truth lives in the Syncthing-shared dotfiles tree so all NixOS
# devices (Diego, Xardas, …) share one file. Edit it once → Syncthing
# propagates → no rebuild needed for the change to take effect (Warp
# re-reads keybindings.yaml on the fly).
#
# mkOutOfStoreSymlink (not normal `source`) is required: a regular `source`
# would copy the file into the read-only Nix store, so cross-device edits
# wouldn't surface without a rebuild.
{
  home.file.".config/warp-terminal/keybindings.yaml".source =
    config.lib.file.mkOutOfStoreSymlink
      "${config.home.homeDirectory}/Syncthing_lighteningv1.0/Technisches/Linux_Setups/dotfiles/config/warp-terminal/keybindings.yaml";
}
