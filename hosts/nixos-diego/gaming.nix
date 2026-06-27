{ lib, config, pkgs, username, inputs, ... }:

let
  # Declarative seed for lsfg-vk's config. Copied to ~/.config/lsfg-vk/conf.toml
  # on first login (systemd.user.tmpfiles `C`, see below) and then left
  # writable so lsfg-vk-ui can edit it — delete the file + `nixos-rebuild
  # switch` to re-seed from this default.
  #
  # `[global].dll` is the one machine-specific bit: the absolute path to the
  # Lossless Scaling DLL (owned via Steam app 993090). It CANNOT go through the
  # module's `losslessDLLFile` option — that's deprecated in lsfg-vk v1.0.0 and
  # only honoured when LSFG_LEGACY is set — so it lives here in [global].dll.
  #
  # Profiles are inert until a game opts in with `LSFG_PROCESS=<name> %command%`
  # (the env var overrides the detected process name so it matches the profile
  # whose `exe` equals that string). performance_mode + a reduced flow_scale
  # keep the optical-flow pass light on the 8060S's shared LPDDR5X bandwidth —
  # the right default for this iGPU; bump flow_scale toward 1.0 per-profile for
  # quality when a game is light enough to spare the bandwidth.
  lsfgVkConf = pkgs.writeText "lsfg-vk-conf.toml" ''
    # SEEDED by NixOS (hosts/nixos-diego/gaming.nix). Writable — edit freely or
    # via lsfg-vk-ui. Delete + `nixos-rebuild switch` to restore this default.

    [global]
    dll = "/home/${username}/.local/share/Steam/steamapps/common/Lossless Scaling/Lossless.dll"

    # Activate per-game from Steam (desktop or Gaming-Mode QAM → Properties →
    # Launch Options):  ENABLE_LSFG=1 LSFG_PROCESS=lsfg2 %command%
    # (ENABLE_LSFG=1 is required — the layer is opt-in, see gaming.nix comment.)
    [[profile]]
    name = "lsfg2"
    exe = "lsfg2"
    multiplier = 2
    flow_scale = 0.75
    performance_mode = true

    [[profile]]
    name = "lsfg3"
    exe = "lsfg3"
    multiplier = 3
    flow_scale = 0.75
    performance_mode = true

    # Quality variant — full flow resolution, heavier. Use for lighter (2D /
    # older) titles that can spare the bandwidth:  LSFG_PROCESS=lsfg2hq %command%
    [[profile]]
    name = "lsfg2hq"
    exe = "lsfg2hq"
    multiplier = 2
    flow_scale = 1.0
    performance_mode = false
  '';
in

{
  # NixOS-Built-in Steam-Wayland-Session deaktivieren (Donvinis modules/gaming.nix
  # setzt programs.steam.gamescopeSession.enable=true). Jovian liefert eine
  # eigene Gaming-Mode-Session und beide würden um services.displayManager.sessionPackages
  # konkurrieren.
  programs.steam.gamescopeSession.enable = lib.mkForce false;

  # NixOS-Standalone-gamescope deaktivieren — Donvinis modules/gaming.nix setzt
  # programs.gamescope.enable=true, was ein zweites gamescope-Binary in
  # environment.systemPackages installiert (Jovians /run/wrappers/bin/gamescope
  # gewinnt im PATH, aber Closure-Bloat ~250 MB und latentes Konflikt-Risiko
  # falls Donvini je capSysNice mitsetzt). Jovian's eigenes gamescope-Setup
  # ist das einzig genutzte.
  programs.gamescope.enable = lib.mkForce false;

  # ─────────────────────────────────────────────────────────────────────
  # Lossless Scaling Frame Generation (lsfg-vk) — opt-IN Vulkan layer.
  #
  # ROOT CAUSE FIX (2026-06-27, ADR-0039 Nachtrag #1): the upstream v1.0.0
  # layer JSON ships "type":"GLOBAL" with ONLY a disable_environment
  # (DISABLE_LSFG=1) and NO enable_environment. Per the Vulkan loader spec an
  # implicit layer with that shape is ENABLED BY DEFAULT — the loader injects
  # liblsfg-vk.so into EVERY Vulkan instance unless DISABLE_LSFG is defined.
  # That includes gamescope-wl itself, the Jovian Gaming-Mode compositor.
  # gamescope is a Vulkan compositor that scans out directly via DRM/KMS
  # atomic commits; the frame-gen layer's WSI/present wrappers corrupt that
  # path, so gamescope's first page-flip fails:
  #     [gamescope] [Error] drm: flip error: Invalid argument
  #     [gamescope] [Error] drm: fatal flip error, aborting
  # → gamescope-wl SIGABRT → the Gaming-Mode session dies → SDDM takes the
  # screen back → "log into Gaming Mode just bounces straight back to SDDM".
  # The earlier "inert passthrough, costs nothing" assumption was WRONG for
  # gamescope: merely LOADING the layer into the compositor breaks scanout,
  # before any profile match. (MangoHud, right next to it in
  # implicit_layer.d, coexists with gamescope precisely because it uses the
  # OPPOSITE polarity — enable_environment MANGOHUD=1, off by default.)
  #
  # Fix: override services.lsfg-vk.package so the installed manifest uses
  # enable_environment (ENABLE_LSFG=1) instead of disable_environment. The
  # module installs cfg.package into BOTH environment.systemPackages and
  # /etc/vulkan/implicit_layer.d/, so this one override flips both copies. The
  # layer is now INACTIVE by default — gamescope, Caelestia, browsers, acrm's
  # apps all run clean — and loads ONLY for a game that opts in. (The package
  # is reachable as inputs.lsfg-vk-flake.packages.<system>.default; the
  # --replace-fail substitutions double as a tripwire if upstream changes the
  # manifest shape.)
  #
  # `enable = true` and `ui.enable = true` come from modules/gaming.nix.
  # The machine-specific DLL path + the opt-in profiles are seeded into
  # conf.toml below.
  #
  # PER-GAME USE — identical in desktop Steam and Gaming-Mode QAM (gear →
  # Properties → Launch Options). Note BOTH vars now: ENABLE_LSFG=1 arms the
  # layer for that process, LSFG_PROCESS picks the conf.toml profile:
  #     ENABLE_LSFG=1 LSFG_PROCESS=lsfg2 %command%     # 2× frames, perf-mode
  #     ENABLE_LSFG=1 LSFG_PROCESS=lsfg3 %command%     # 3× frames
  #     ENABLE_LSFG=1 LSFG_PROCESS=lsfg2hq %command%   # 2× frames, full quality
  # (Any game previously configured with bare `LSFG_PROCESS=… %command%` must
  # be updated to prepend `ENABLE_LSFG=1` or it will no longer frame-gen.)
  # Audio + the performance overlay stay on the normal Gaming-Mode QAM; the
  # overlay's FPS counter reports the *generated* rate.
  #
  # CAVEAT (upstream Gamescope-Compatibility wiki): cap the game with its OWN
  # in-game frame limiter (or leave uncapped) — gamescope's frame limiter
  # fights lsfg-vk. Set the in-game cap near half the panel refresh so the
  # multiplied output lands on the panel rate.
  #
  # lsfg-vk-ui (the GTK config GUI, from ui.enable) runs in the Hyprland
  # desktop, not inside Gaming Mode — use it to tweak profiles; the per-game
  # toggle in Gaming Mode is the launch option above.
  #
  # Revert: drop the package override below (back to the broken-for-gamescope
  # default) or re-add `services.lsfg-vk.enable = lib.mkForce false;`.
  #
  # MECHANISM (verified at runtime via VK_LOADER_DEBUG): the Vulkan loader
  # treats `disable_environment` as REQUIRED for an implicit layer — removing
  # it makes the loader skip the layer entirely ("doesn't contain required
  # layer object disable_environment … skipping"). So we KEEP the required
  # `disable_environment` (DISABLE_LSFG) and ADD an `enable_environment`
  # (ENABLE_LSFG) alongside it. With both keys present the layer is opt-in:
  # loaded only when ENABLE_LSFG is set, force-off when DISABLE_LSFG is set —
  # the exact polarity MangoHud ships. (Replacing instead of adding the key
  # would silently break per-game frame-gen for everyone — it merely *looks*
  # like it fixed gamescope because a skipped layer also can't crash it.)
  # What keeps gamescope clean: ENABLE_LSFG is set ONLY per-game (in the game's
  # Steam launch option, applied to the game process), never in gamescope's own
  # session environment — so the compositor's Vulkan instance never gates the
  # layer on. Verified at runtime (VK_LOADER_DEBUG, real gamescope binary): no
  # ENABLE_LSFG → layer NOT loaded into gamescope, no DRM flip, Vulkan inits;
  # ENABLE_LSFG=1 on a game process → layer loads → frame-gen. (The loader reads
  # enable/disable_environment with plain getenv, so gamescope being setcap does
  # NOT itself block it — rely on ENABLE_LSFG staying per-game, MangoHud's model.)
  services.lsfg-vk.package =
    inputs.lsfg-vk-flake.packages.${pkgs.stdenv.hostPlatform.system}.default.overrideAttrs (old: {
      postPatch = (old.postPatch or "") + ''
        substituteInPlace VkLayer_LS_frame_generation.json \
          --replace-fail '"disable_environment": {' '"enable_environment": { "ENABLE_LSFG": "1" }, "disable_environment": {'
      '';
    });

  # RDNA 3.5 (Strix Halo gfx1151) Mesa/RADV-Tuning (Plan-0007 F8, ADR-0028):
  # - video_encode: Vulkan-Video-Encoder für Steam-Link-VR-Streaming (HEVC
  #   hardware-encoded auf-Host für Pico-4 Steam-Link). Mesa 25.2+ Pflicht.
  # - sam: Smart Access Memory (PCIe-Resizable-BAR) — full GPU-Resource-Mapping.
  #
  # Entfernt: gpl + nggc — auf RDNA 3.5 (GFX10.3+) bereits Mesa-default seit
  # Commit 52413a9; explicit-setzen war 2026-Cargo-Cult (Phoronix Mesa 25.2
  # Strix-Halo-Review). RADV-Docs: https://docs.mesa3d.org/drivers/radv.html
  environment.sessionVariables.RADV_PERFTEST = "video_encode,sam";

  # ─────────────────────────────────────────────────────────────────────
  # Proton-CachyOS (FSR4) — expose to BOTH sessions (ADR-0038 Nachtrag #1)
  #
  # modules/gaming.nix delivers proton-cachyos via
  # `programs.steam.extraCompatPackages`. Both the desktop Steam and the
  # Jovian Gaming-Mode Steam are FHS/bwrap-wrapped, and BOTH inherit the same
  # session var STEAM_EXTRA_COMPAT_TOOLS_PATHS=~/.steam/root/compatibilitytools.d
  # (set by modules/gaming.nix). The divergence is INSIDE the sandbox:
  # extraCompatPackages bakes STEAM_EXTRA_COMPAT_TOOLS_PATHS=<proton-cachyos
  # store path> into the fhsenv /etc/profile of `programs.steam.package` (the
  # DESKTOP build — proton-cachyos is in that build's closure), which
  # overrides the inherited empty-dir value before Proton is spawned. So
  # desktop Steam resolves the tool → FSR4 works.
  #
  # Jovian's Gaming Mode runs a DIFFERENT, vanilla steam fhsenv build: its
  # gamescope-session/lib/steamos/steam-launcher `exec`s a SEPARATE steam
  # derivation whose closure does NOT contain proton-cachyos and whose fhsenv
  # /etc/profile has an empty injection block. So in Gaming Mode the var stays
  # at ~/.steam/root/compatibilitytools.d — which was EMPTY → the per-game
  # forced compat tool (CompatToolMapping → "proton-cachyos-…-x86_64_v3")
  # fails to resolve → Steam exec's the raw Windows .exe ("cannot execute
  # binary file") → the game exits instantly → gamescope's xwm aborts on the
  # resulting X11 I/O error → SIGABRT takes down the whole game-mode session.
  # (Root-caused + adversarially verified 2026-06-13: console_log.txt:925 the
  # desktop run executed the proton chain; :1091/:1115 game mode ran the raw
  # exe; steam closures contain proton-cachyos 1× desktop / 0× game-mode.)
  #
  # NB: it is NOT a "wrapped vs bare" difference (both are FHS-wrapped) and
  # NOT an "env present vs absent" difference (both inherit the same session
  # var) — it is two DIFFERENT steam derivations, only one of which has
  # extraCompatPackages baked into its fhsenv /etc/profile.
  #
  # Fix: expose the tool through Steam's *native* user compat-tools dir
  # ~/.steam/root/compatibilitytools.d/, which steamclient.so scans
  # UNCONDITIONALLY in EVERY launch path (desktop fhsenv + gamepadui),
  # independent of the env var — exactly like protonup-installed GE builds.
  # The internal tool name inside compatibilitytool.vdf is unchanged
  # (proton-cachyos-…-x86_64_v3), so the existing per-game CompatToolMapping
  # keeps resolving. extraCompatPackages stays as-is (harmless: identical
  # internal name + store path; kept as the desktop safety net so this change
  # can't regress the already-working Hyprland path).
  #
  # Mechanism = user-instance tmpfiles, NOT system tmpfiles: ~/.steam/root is
  # a marius-owned symlink → ~/.local/share/Steam, and the system (root)
  # tmpfiles refuses to canonicalize through it ("unsafe path transition
  # …owned by marius → owned by root"). Running as the user, and pointing at
  # the canonical ~/.local/share/Steam path (no symlink in the chain),
  # sidesteps that entirely. Applies at user-session start; on a live switch
  # it's created out-of-band the first time, then self-heals every login.
  systemd.user.tmpfiles.rules = [
    "L+ %h/.local/share/Steam/compatibilitytools.d/proton-cachyos-fsr4 - - - - ${pkgs.proton-cachyos.steamcompattool}"

    # lsfg-vk config seed (see lsfgVkConf in the let-block + the lsfg-vk comment
    # above). `d` ensures the dir; `C` copies the seed ONLY if conf.toml does
    # not exist yet, then leaves it user-writable so lsfg-vk-ui can edit it —
    # no read-only HM symlink, so no Caelestia-style auto-save conflict.
    "d %h/.config/lsfg-vk 0755 ${username} users - -"
    "C %h/.config/lsfg-vk/conf.toml 0644 ${username} users - ${lsfgVkConf}"
  ];

  jovian = {
    steam = {
      enable = true;
      autoStart = false;
      # NOTE: `jovian.steam.desktopSession` is deliberately NOT set here.
      # autostart.nix:106 reads cfg.desktopSession exactly once, inside
      # `mkIf cfg.autoStart` — with autoStart=false it's dead Nix code and
      # Jovian itself emits an eval warning if we set it. The runtime
      # mechanism is `steamosctl set-default-desktop-session`, which writes
      # to ~/.local/state/steamos-manager/state.toml; we replicate Jovian's
      # oneshot below (`systemd.user.services.set-steamos-desktop-session`),
      # un-gated on autoStart so the value propagates on every login.
      user = "marius";
    };

    hardware.has.amd.gpu = true;

    # SteamOS-Defaults granular whitelisten statt useSteamOSConfig=true:
    # Default zieht audit=0, amd_iommu=off (DMA-Risiko via USB4!),
    # offene NetworkManager-Polkit-Rule, screen-reader Default-on,
    # /sys/class/dmi/id/product_serial relaxed auf wheel-readable, u.a.
    # — alles SteamDeck-spezifisch und auf einem Multi-Purpose-Laptop falsch.
    steamos = {
      useSteamOSConfig = lib.mkForce false;
      enableEarlyOOM = true;       # OOM-killer verhindert System-Freeze
      enableSysctlConfig = true;   # Gaming-sysctls (vm.max_map_count etc.)
    };
  };

  # 8BitDo Ultimate 2 Wireless — USB-Device-Node-Zugriff fuer den offiziellen
  # Web-Firmware-Updater (web.8bitdo.com, WebUSB, nur Chromium). Valve's
  # 60-steam-input.rules (hardware.steam-hardware via programs.steam) deckt
  # vendor 2dc8 nur fuer hidraw + uinput ab — WebUSB braucht /dev/bus/usb.
  # Controller-Betrieb selbst braucht diese Rule NICHT (BT-DInput laeuft
  # ueber uhid/hidraw); sie existiert rein fuer Firmware-Updates ohne Windows.
  # Firmware >= v1.03 ist das Gate fuer volle Steam/SDL3-HIDAPI-Unterstuetzung
  # (Gyro, Back-Buttons, Rumble) ueber Bluetooth.
  services.udev.extraRules = ''
    SUBSYSTEM=="usb", ATTRS{idVendor}=="2dc8", TAG+="uaccess"
  '';

  # galileo-mura-extractor (Steam Deck OLED Pixel-Uniformity-Calibration)
  # setuid-root durch Jovian, auf Strix Halo funktionslos — kein OLED-Display,
  # keine Mura-Daten. setuid-Bit weg = keine Privilege-Eskalations-Surface;
  # Binary bleibt im PATH (würde ohne Steam-Deck-Hardware eh nichts machen).
  security.wrappers.galileo-mura-extractor.setuid = lib.mkForce false;

  # AMD-IOMMU explizit auf NixOS-Default (Jovian würde mit useSteamOSConfig=true
  # deaktivieren). iommu=pt = passthrough-mode, schützt vor DMA-Attacks via
  # USB4/Thunderbolt ohne signifikanten Performance-Cost.
  #
  # `audit=1` wurde ENTFERNT: NixOS aktiviert keinen auditd-Userspace-Daemon
  # mit (`security.auditd.enable` default false). Mit `audit=1` füllt der
  # Kernel kauditd's 64-Slot-Hold-Queue innerhalb von Sekunden, ohne dass
  # irgendwer drain't — Resultat ist die Flut von `audit: kauditd hold queue
  # overflow` in dmesg/journalctl -k (+ stiller `audit_lost`-Increment).
  # Falls Audit-Logging je gebraucht wird: `security.auditd.enable = true;`
  # UND `audit=1` zurück hinzufügen — die beiden gehören paarweise oder gar
  # nicht. Reines `audit=0` wäre überflüssig; ohne Kernel-Param landet das
  # Subsystem im "compiled-in but inactive"-Zustand, der nichts emittiert.
  boot.kernelParams = [
    "amd_iommu=on"
    "iommu=pt"
    # Crash-Mitigation (2026-06-26): SMU-Mailbox-Contention zwischen ryzen_smu
    # (ryzenadj-TDP-Writes) und amdgpu wedget unter Last + AC-Flap die SMU →
    # `ring gfx_0.0.0 timeout` → GPU-Reset scheitert (braucht die tote SMU) →
    # `flip_done timed out` → Hard-Freeze (musste per Power-Knopf hart aus).
    # gpu_recovery=1 erzwingt einen MODE2-Reset-Pfad, der den Hang in einen
    # *recoverbaren* Reset statt Einfrieren verwandelt — auf genau dieser
    # Signatur bestätigt (Framework gfx-ring-timeout-Thread, ryzenadj #372).
    # Verhindert den Wedge NICHT; das eigentliche Root-Cause-Fix (ryzen_smu vs.
    # amdgpu) ist ein separates Thema — siehe ac-power-mode.nix/gamescope-power.nix.
    "amdgpu.gpu_recovery=1"
  ];

  # Pin the default desktop session for steamos-manager. Without this,
  # the Power-Menu's "Switch to Desktop" fails with
  # `I/O error: No such file or directory` because steamos-manager's
  # state file `~/.local/state/steamos-manager/state.toml` doesn't exist
  # yet. Jovian's autostart.nix:106 provisions an identical oneshot but
  # only under `mkIf cfg.autoStart`. We're on autoStart=false so we
  # replicate it ourselves, un-gated. Value is derived from
  # services.displayManager.defaultSession, which Diego pins to
  # "hyprland-uwsm" in default.nix (ADR-0017) so the Gamescope→Hyprland
  # return path lands in the UWSM-managed session that switch-to-game-mode
  # also depends on. Touching defaultSession upstream now propagates here
  # automatically without code change.
  systemd.user.services.set-steamos-desktop-session = {
    description = "Pin steamos-manager default desktop session";
    wants = [ "steamos-manager.service" ];
    after = [ "steamos-manager.service" ];
    wantedBy = [ "graphical-session.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart =
        "${pkgs.steamos-manager}/bin/steamosctl set-default-desktop-session "
        + "${config.services.displayManager.defaultSession}.desktop";
    };
  };
}
