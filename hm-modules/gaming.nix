{ pkgs, ... }:

let
  # FSR 4 verification command (ADR-0038). Body lives in ./fsr4-check.sh so it
  # gets build-time shellcheck and stays readable; writeShellApplication injects
  # the shebang + `set -euo pipefail`. Confirms the proton-cachyos RDNA 3.5
  # DLL-upgrade is actually engaged for a game (DLL hash + protonfixes signal +
  # live process env), since nothing in-game or in MangoHud reports it.
  fsr4-check = pkgs.writeShellApplication {
    name = "fsr4-check";
    runtimeInputs = with pkgs; [ coreutils gnugrep ];
    text = builtins.readFile ./fsr4-check.sh;
  };
in
{
  home.packages = [ fsr4-check ];

  # MangoHud overlay cockpit (user scope; ADR-0038). MangoHud is a Vulkan
  # present-layer overlay, so it CANNOT show whether in-game FSR 4 is active
  # (FidelityFX runs upstream of the swapchain) — that's what `fsr4-check` is
  # for. What MangoHud DOES answer: (a) "is my Proton/Vulkan/GPU stack right?"
  # via engine_version + vulkan_driver + gpu_name, and (b) "what does the
  # FSR4 FP8-emulation cost?" via gpu_power/clocks/load + fps/frametime.
  #
  # Shows when a game is launched with `mangohud %command%` (combine with the
  # FSR4 var: `PROTON_FSR4_RDNA3_UPGRADE=1 mangohud %command%`), or toggled in
  # Gaming Mode's QAM (gamescope's mangoapp reads this same config). Toggle the
  # overlay with Shift_R+F12. NB: `resolution` is the swapchain (output) res,
  # NOT the internal render res — it cannot reveal in-game upscaling.
  programs.mangohud = {
    enable = true;
    settings = {
      # --- stack identity: "is the plumbing right?" ---
      gpu_name = true;
      engine_version = true; # DXVK / VKD3D-Proton version
      vulkan_driver = true;  # RADV + Mesa version (FP8 floor at a glance)
      wine = true;           # Proton version
      # --- cost: "what does FSR4 FP8-emulation cost vs FSR 3.1?" ---
      fps = true;
      frametime = true;
      frame_timing = true;
      gpu_stats = true;      # GPU load %
      gpu_temp = true;
      gpu_power = true;
      gpu_core_clock = true;
      gpu_mem_clock = true;
      vram = true;           # shared/GTT on the 8060S iGPU
      cpu_stats = true;
      cpu_temp = true;
      cpu_power = true;
      ram = true;
      # --- context (output res, not render res — see note above) ---
      resolution = true;
      # --- presentation ---
      legacy_layout = 0;     # modern table layout
      position = "top-left";
      font_size = 20;
      background_alpha = "0.4";
      round_corners = 10;
      toggle_hud = "Shift_R+F12";
      toggle_logging = "Shift_L+F2";
    };
  };
}
