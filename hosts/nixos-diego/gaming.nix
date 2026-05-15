{ ... }:

{
  programs = {
    steam.gamescopeSession = {
      args = [
        "--adaptive-sync"
        "--mangoapp"
        "--rt"
      ];
      steamArgs = [
        "-gamepadui"
        "-steamdeck"
        "-steamos3"
        "-pipewire-dmabuf"
      ];
    };

    gamescope.capSysNice = true;
  };
}
