{ pkgs, ... }:

{
  programs.helix = {
    enable = true;
    settings = {
      theme = "autumn_night_transparent";
      editor = {
        # Plan-0003 F4: save on focus-lost AND on 2s idle-timeout. Plan-0002
        # ships `DefaultTimeoutStopSec=5s` for user app-scopes; without
        # autosave a session-switch SIGKILL would lose unsaved helix buffers.
        # Struct form needed because the bool shorthand (`auto-save = true`)
        # only covers focus-lost — verified against helix-view/src/editor.rs
        # 1055-1099 (PR #10899, Helix 24.07+). 2000 ms timeout is more
        # aggressive than Helix's 3000 ms default; pairs with the 5 s SIGKILL.
        auto-save = {
          focus-lost = true;
          after-delay = {
            enable  = true;
            timeout = 2000;
          };
        };
        cursor-shape = {
          normal = "block";
          insert = "bar";
          select = "underline";
        };
      };
    };
    languages.language = [
      {
        name = "nix";
        auto-format = true;
        formatter.command = "${pkgs.nixfmt}/bin/nixfmt";
      }
    ];
    themes = {
      autumn_night_transparent = {
        "inherits" = "autumn_night";
        "ui.background" = { };
      };
    };
  };
}
