{ ... }:
{
  programs.kitty = {
    enable = true;
    font = {
      name = "Iosevka Term";
      size = 18;
    };
    themeFile = "Modus_Vivendi_Tinted";
    shellIntegration.enableFishIntegration = true;
    keybindings = {
      # Window navigation (vim hjkl — shadows ctrl+l clear and ctrl+j newline in shell)
      "ctrl+h" = "neighboring_window left";
      "ctrl+j" = "neighboring_window down";
      "ctrl+k" = "neighboring_window up";
      "ctrl+l" = "neighboring_window right";

      # Splits (mirrors vim <C-w>v / <C-w>s)
      # Naming-Falle: Kitty's `hsplit` = horizontale Trennlinie = Fenster
      # übereinander; `vsplit` = vertikale Trennlinie = Fenster nebeneinander.
      "ctrl+backslash" = "launch --location=vsplit";
      "ctrl+minus" = "launch --location=hsplit";   # Fenster darunter
      "ctrl+plus" = "launch --location=vsplit";    # Fenster daneben
      "ctrl+shift+w" = "close_window";

      # Tabs (bracket nav, doom-style)
      "ctrl+t" = "new_tab";
      "ctrl+shift+t" = "close_tab";
      "ctrl+shift+]" = "next_tab";
      "ctrl+shift+[" = "previous_tab";

      # Scrollback in nvim
      "ctrl+shift+s" = "show_scrollback";
    };
    environment = {
      "LANG" = "en_US.UTF-8";
    };
    settings = {
      # Disable kitty's live config-reload watcher. Default 0.1 spawns a
      # `kitten __watch_conf__` child that — when kitty.conf is a SYMLINK, as it
      # always is under home-manager (~/.config/kitty/kitty.conf → /nix/store/…) —
      # mis-watches and recursively inotify-watches all of $HOME (~500k entries),
      # exhausting fs.inotify.max_user_watches. That starves every other app of
      # watches; concretely it broke caelestia's scheme.json watch, so the bar
      # stopped following darkman dark/light toggles (Ctrl+Alt+T). See kitty
      # issue #10066. A negative value disables the watcher; the config is
      # immutable nix-store state anyway so live reload buys us nothing. Manual
      # reload remains available via ctrl+shift+f5 (reload_config_file).
      auto_reload_config = -1;
      shell = "fish";
      scrollback_lines = 10000;
      scrollback_pager = "nvim -c 'set ft=man' -";
      cursor_shape = "beam";
      window_padding_width = 8;
      confirm_os_window_close = 0;
      background_opacity = "0.9";
      tab_bar_style = "powerline";
      tab_powerline_style = "slanted";
      enabled_layouts = "splits,tall,stack";
      allow_remote_control = "socket-only";
      listen_on = "unix:/tmp/kitty";
    };
  };
}
