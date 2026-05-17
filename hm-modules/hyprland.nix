{
  pkgs,
  lib,
  osConfig,
  ...
}:
# Hyprland config for Nixos-Diego — Marius's keybinds ported onto donvini's
# NixOS base. See HANDOVER.md for full decision history (Frage 1–13 +
# 22 Launcher-Konflikte) and target file location.
#
# Drop-in replacement for donvini's hm-modules/hyprland.nix.
#
# Design choices:
#   - Layout: master (donvini)            — Frage 2
#   - Tastaturlayout: kb_layout = de       — Frage 3
#   - Workspace-Groups: aus                — Frage 1
#   - Borders/Gaps/Opacity: Marius-Werte   — Tier 3 Visuals
#   - 22 Launcher-Bindings: siehe HANDOVER — Frage 4.1–4.22
#   - Movement (focus/window/workspace): Marius-Schema (Pfeiltasten)
let
  # Alt+V → take the image currently on the Wayland clipboard, save it to
  # /tmp, then *replace* the clipboard contents with the file path as text.
  # User then presses Ctrl+V normally in Warp/Claude Code to paste the path.
  #
  # Why not type the path directly with wtype? wtype emits raw keysyms via
  # the virtual-keyboard-v1 protocol. The compositor still sees the physical
  # Alt as held during typing, so each character gets re-interpreted as an
  # Alt+<key> shortcut (Warp/Hyprland/Claude eat or remap it). Documented
  # workaround in the Hyprland community: don't type, hand off via clipboard.
  # https://bbs.archlinux.org/viewtopic.php?id=303538
  #
  # Why text-only and not multi-MIME (text/plain + x-special/gnome-copied-files
  # so Thunar can paste the file)? Tried that via `cb` (clipboard-jh) — it works
  # for a single invocation, but each `cb copy` spawns a persistent Wayland
  # clipboard-source daemon, and successive invocations fight each other for
  # selection ownership (~2s re-claim cycle). The compositor opens/closes the
  # source surface on each re-claim, which steals focus and triggers kitty's
  # resize banner on every other window — the system becomes unusable. wl-copy
  # daemonises cleanly but only supports a single --type per invocation, so
  # genuine multi-MIME isn't reachable with stock wl-clipboard. Trade-off: keep
  # text-only; if file-paste-in-Thunar is needed, drag-and-drop from the
  # notification or use the screenshot cache directly.
  cc-paste-image = pkgs.writeShellApplication {
    name = "cc-paste-image";
    runtimeInputs = with pkgs; [
      wl-clipboard
      libnotify
      coreutils
    ];
    text = ''
      ts=$(date +%Y%m%d%H%M%S)
      out="/tmp/cc-paste-''${ts}.png"
      log=/tmp/cc-paste.log

      {
        echo "[$(date -Iseconds)] start"

        if wl-paste --list-types 2>/dev/null | grep -q '^image/'; then
          wl-paste --type image/png > "$out" 2>/dev/null || true
          echo "  source=clipboard size=$(stat -c%s "$out" 2>/dev/null || echo 0)"
        fi

        if [ ! -s "$out" ]; then
          cache="$HOME/.cache/caelestia/screenshots"
          if [ -d "$cache" ]; then
            # find -printf '%T@ %p' → mtime + path, sort newest-first
            latest=$(find "$cache" -maxdepth 1 -type f -printf '%T@ %p\n' 2>/dev/null \
                     | sort -rn | head -1 | cut -d' ' -f2-)
            if [ -n "$latest" ] && [ -s "$latest" ]; then
              cp "$latest" "$out"
              echo "  source=cache file=$latest"
            fi
          fi
        fi
      } >> "$log"

      if [ ! -s "$out" ]; then
        notify-send -u normal -i image-x-generic-symbolic \
          "cc-paste" "No image in clipboard or screenshot cache"
        echo "  FAIL: no image source" >> "$log"
        exit 1
      fi

      # Replace clipboard contents with the file path as text. User then
      # presses Ctrl+V (Warp's normal paste) to insert the path into the
      # focused prompt — works in any app, no Alt-modifier race.
      printf '%s ' "$out" | wl-copy --type text/plain
      notify-send -u low -i image-x-generic-symbolic \
        -h "STRING:image-path:$out" \
        "Screenshot ready" "Pfad im Clipboard — Ctrl+V zum Einfügen"
      {
        echo "  path copied to clipboard: $out"
        echo "[$(date -Iseconds)] done"
      } >> "$log"
    '';
  };
in
{
  wayland.windowManager.hyprland = {
    enable = true;
    settings = {
      env = [
        # GPU device: Strix Halo AMD iGPU is the only DRM device — let Aquamarine
        # auto-detect. Hardcoding /dev/dri/cardN is brittle (kernel-assigned
        # numbering varies, e.g. card1 on this host) and unnecessary on a
        # single-GPU machine.

        # Wayland / toolkit
        "XDG_SESSION_TYPE,wayland"
        "XDG_CURRENT_DESKTOP,Hyprland"
        "ELECTRON_OZONE_PLATFORM_HINT,auto"
        "NIXOS_OZONE_WL,1"
        "QT_QPA_PLATFORMTHEME,qt6ct"

        # Cursor (Marius-Default)
        "XCURSOR_SIZE,24"
        "XCURSOR_THEME,Bibata-Modern-Ice"
        "HYPRCURSOR_THEME,Bibata-Modern-Ice"
        "HYPRCURSOR_SIZE,24"
      ];

      cursor.no_hardware_cursors = true;

      exec-once = [
        "/run/current-system/sw/libexec/polkit-kde-authentication-agent-1"
        "keepassxc /home/marius/Syncthing_lighteningv1.0/Organisatorisches/MRPrivat.kdbx"
        "nm-applet --indicator"
        "wl-paste --type text --watch cliphist store -max-items 100 -max-size 2000000"
        "wl-paste --type image --watch cliphist store -max-items 100 -max-size 2000000"
        "hyprctl setcursor Bibata-Modern-Ice 24"
        "mpris-proxy"
      ];

      monitor = ",highres@highrr,auto,auto";

      input = {
        # Frage 3: kb_layout = de only, kein caps:escape, kein Toggle
        kb_layout = "de";
        follow_mouse = 1;
        repeat_rate = 50;
        repeat_delay = 400;
        touchpad = {
          natural_scroll = false;
          disable_while_typing = true;
        };
        sensitivity = "1.0";
      };

      general = {
        # Tier 3: Marius-Werte
        gaps_in = 5;
        gaps_out = 15;
        border_size = 3;
        # Theme-driven colors (folgen Caelestia-Scheme via $-Variablen aus scheme/current.conf)
        # Diese Strings werden von Hyprland nach Caelestia-Scheme-Reload neu evaluiert.
        "col.active_border" = "rgba(33ccffee) rgba(00ff99ee) 45deg";  # Fallback gradient bis scheme/current.conf greift
        "col.inactive_border" = "rgba(595959aa)";
        # Frage 2: Master-Layout
        layout = "master";
      };

      decoration = {
        # Tier 3: Marius rounding=10 statt donvini 16
        rounding = 10;
        # Window-Opacity 0.85 (Marius)
        active_opacity = 1.0;
        inactive_opacity = 0.85;
        blur = {
          enabled = true;
          size = 8;
          passes = 2;
          new_optimizations = true;
          brightness = 1.0;
          noise = 0.02;
        };
      };

      xwayland.force_zero_scaling = true;

      animations = {
        enabled = true;
        animation = [
          "border, 1, 2, default"
          "fade, 1, 2, default"
          "windows, 1, 2, default, popin 80%"
          "workspaces, 1, 2, default, slide"
        ];
      };

      # Master-layout settings (Frage 2)
      master.new_status = "inherit";

      misc = {
        enable_swallow = true;
        force_default_wallpaper = 0;
      };

      "$mod" = "SUPER";

      # Super-Tap-Launcher entfernt — Marius wollte nicht dass Super-allein
      # den Launcher öffnet (zu viele Fehlauslöser). Launcher liegt jetzt
      # explizit auf Super+R im bind-Block unten. bindi/bindin-Pattern raus,
      # die mouse-Interrupts waren nur Tap-Cancel und ohne bindi obsolet.

      bind = [
        # ── Caelestia Shell Integrations ─────────────────────────
        "$mod, R, global, caelestia:launcher"
        "CTRL ALT, Delete, global, caelestia:session"
        "CTRL ALT, C, global, caelestia:clearNotifs"
        "$mod, K, global, caelestia:showall"
        "$mod, BackSpace, global, caelestia:sidebar"

        # Lock (Frage 4.22: Donvini-Pattern Shift+L, Suspend nur via Session-Menü)
        "$mod SHIFT, L, global, caelestia:lock"

        # ── Brightness (Caelestia handles via global) ────────────
        ", XF86MonBrightnessUp, global, caelestia:brightnessUp"
        ", XF86MonBrightnessDown, global, caelestia:brightnessDown"

        # ── Media ────────────────────────────────────────────────
        "CTRL $mod, Space, global, caelestia:mediaToggle"
        ", XF86AudioPlay, global, caelestia:mediaToggle"
        ", XF86AudioPause, global, caelestia:mediaToggle"
        "CTRL $mod, Equal, global, caelestia:mediaNext"
        ", XF86AudioNext, global, caelestia:mediaNext"
        "CTRL $mod, Minus, global, caelestia:mediaPrev"
        ", XF86AudioPrev, global, caelestia:mediaPrev"
        ", XF86AudioStop, global, caelestia:mediaStop"

        # ── Shell kill/restart ───────────────────────────────────
        "CTRL $mod SHIFT, R, exec, qs -c caelestia kill"
        "CTRL $mod ALT, R, exec, qs -c caelestia kill; sleep .1; caelestia shell -d"

        # ── Workspaces (Frage 1: KEINE Groups, klassisch 1-10) ───
        "$mod, 1, workspace, 1"
        "$mod, 2, workspace, 2"
        "$mod, 3, workspace, 3"
        "$mod, 4, workspace, 4"
        "$mod, 5, workspace, 5"
        "$mod, 6, workspace, 6"
        "$mod, 7, workspace, 7"
        "$mod, 8, workspace, 8"
        "$mod, 9, workspace, 9"
        "$mod, 0, workspace, 10"

        # Move window to workspace 1–10 (Marius: Super+Alt+N statt donvini's Super+Shift+N)
        "$mod ALT, 1, movetoworkspace, 1"
        "$mod ALT, 2, movetoworkspace, 2"
        "$mod ALT, 3, movetoworkspace, 3"
        "$mod ALT, 4, movetoworkspace, 4"
        "$mod ALT, 5, movetoworkspace, 5"
        "$mod ALT, 6, movetoworkspace, 6"
        "$mod ALT, 7, movetoworkspace, 7"
        "$mod ALT, 8, movetoworkspace, 8"
        "$mod ALT, 9, movetoworkspace, 9"
        "$mod ALT, 0, movetoworkspace, 10"

        # Workspace ±1 navigation
        "$mod, Page_Up, workspace, -1"
        "$mod, Page_Down, workspace, +1"
        "$mod, mouse_down, workspace, -1"
        "$mod, mouse_up, workspace, +1"
        "$mod ALT, Page_Up, movetoworkspace, -1"
        "$mod ALT, Page_Down, movetoworkspace, +1"
        "$mod ALT, mouse_down, movetoworkspace, -1"
        "$mod ALT, mouse_up, movetoworkspace, +1"
        "CTRL $mod SHIFT, right, movetoworkspace, +1"
        "CTRL $mod SHIFT, left, movetoworkspace, -1"

        # Special workspace (Marius pattern)
        "$mod, S, togglespecialworkspace, special"
        "CTRL $mod SHIFT, up, movetoworkspace, special:special"
        "CTRL $mod SHIFT, down, movetoworkspace, e+0"
        "$mod ALT, S, movetoworkspace, special:special"

        # ── Window Groups ────────────────────────────────────────
        "ALT, Tab, cyclenext"
        "SHIFT ALT, Tab, cyclenext, prev"
        "CTRL ALT, Tab, changegroupactive, f"
        "CTRL SHIFT ALT, Tab, changegroupactive, b"
        "$mod, comma, togglegroup"
        "$mod, U, moveoutofgroup"
        "$mod SHIFT, comma, lockactivegroup, toggle"

        # ── Window Actions (Marius — Pfeiltasten) ────────────────
        "$mod, left, movefocus, l"
        "$mod, right, movefocus, r"
        "$mod, up, movefocus, u"
        "$mod, down, movefocus, d"
        "$mod SHIFT, left, movewindow, l"
        "$mod SHIFT, right, movewindow, r"
        "$mod SHIFT, up, movewindow, u"
        "$mod SHIFT, down, movewindow, d"
        # Note: Super+H/L sind für master-mfact reserviert (siehe weiter unten)

        # Center, PIP, Pin
        "CTRL $mod, backslash, centerwindow, 1"
        "CTRL $mod ALT, backslash, resizeactive, exact 55% 70%"
        "CTRL $mod ALT, backslash, centerwindow, 1"
        "$mod ALT, backslash, exec, caelestia resizer pip"

        # Fullscreen / Float / Close
        "$mod, F, fullscreen, 0"
        "$mod ALT, F, fullscreen, 1"
        "$mod SHIFT, Space, togglefloating"
        "$mod, Q, killactive"

        # ── Master-Layout-spezifisch (Frage 2: master) ───────────
        "$mod, H, layoutmsg, mfact -0.05"
        "$mod, L, layoutmsg, mfact +0.05"
        "$mod, Space, layoutmsg, swapwithmaster"

        # ── Special Workspace Toggles ────────────────────────────
        "CTRL SHIFT, Escape, exec, caelestia toggle sysmon"
        "$mod, D, exec, caelestia toggle communication"
        # Music-Toggle entfällt (Super+M → thunderbird, Frage 4.16)
        # Todo-Toggle entfällt (Super+R jetzt = Launcher, siehe oben)

        # ── App Launcher (Frage 4.1-4.22) ────────────────────────
        # Marius wins
        "$mod, T, exec, app2unit -- kitty"                                                   # 4.13 — Terminal
        "$mod, W, exec, app2unit -- zen"                                                     # 4.14 — Browser (moved from B)
        "$mod, V, exec, caelestia clipboard"                                                 # 4.21 — Clipboard
        "$mod ALT, V, exec, caelestia clipboard -d"                                          # Marius Bonus
        "$mod, period, exec, caelestia emoji -p"                                             # Marius Bonus
        "$mod SHIFT, M, exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"                    # Marius — Mute Toggle
        "$mod ALT, E, exec, app2unit -- nemo"                                                # Marius Bonus
        "CTRL ALT, Escape, exec, app2unit -- qps"                                            # Marius — qps task switcher
        "CTRL ALT, V, exec, app2unit -- pavucontrol"                                         # Marius — pavucontrol (parallel zu Super+Shift+P)

        # Donvini wins
        "$mod, B, exec, app2unit -- blueman-manager"                                         # 4.14 — Bluetooth
        "$mod, E, exec, emacsclient -a '' -c"                                                # 4.19 — Emacs (Doom)
        "$mod, C, exec, emacsclient -a '' -n -e '(make-orgcapture-frame)'"                   # 4.20 — Org-Capture
        "$mod, M, exec, app2unit -- thunderbird"                                             # 4.16 — Thunderbird
        "$mod, A, exec, steam-run anki"                                                      # 4.2 — Anki
        "$mod, N, exec, kitty -e yazi"                                                       # 4.3 — Yazi TUI Filemanager
        # 4.4 — Steam with MangoHud — see Gaming-Mode block below: on
        # jovian-equipped hosts this lives on $mod SHIFT, G (and $mod, G
        # becomes the Gaming-Mode session switch); on non-jovian hosts it
        # keeps donvini's original $mod, G slot.
        "$mod, O, exec, emacsclient -a '' -e '(org-agenda nil \"a\")'"                       # 4.5 — Org-Agenda
        "$mod, Z, exec, app2unit -- zotero"                                                  # 4.12 — Zotero

        # Shift = direct app variant (Frage 4.6-4.10)
        "$mod SHIFT, N, exec, app2unit -- thunar"                                            # 4.6 — Thunar (GUI Filemanager)
        "$mod SHIFT, D, exec, app2unit -- discord"                                           # 4.7 — Discord
        "$mod SHIFT, T, exec, app2unit -- telegram-desktop"                                  # 4.8 — Telegram
        "$mod SHIFT, P, exec, app2unit -- pavucontrol"                                       # 4.10 — Pavucontrol
        "$mod SHIFT, C, exec, app2unit -- codium"                                            # 4.20 — Codium

        # System Toggles (Ctrl+Alt-Namespace, Frage 4.13)
        "CTRL ALT, T, exec, darkman toggle"                                                  # darkman dark/light

        # Password Manager (Frage 4.18 — Custom für KeePassXC statt donvini's wofi-pass)
        # Moved from $mod+P → $mod+SHIFT+K so $mod+P is free for `power-mode cycle`
        # (K mnemonic = KeePass).
        "$mod SHIFT, K, exec, keepmenu"

        # Color Picker (Marius — moved aus Super+Shift+C wo's mit Codium kollidierte)
        "$mod ALT, C, exec, hyprpicker -a"

        # ── Screenshots / Recording (Frage 4.11 — Marius gewinnt Super+Shift+S) ─
        ", Print, exec, caelestia screenshot"                                                # Full screen → clipboard
        # Direkt-ins-Clipboard-Varianten (umgehen swappy — der ist auf Diego
        # nicht installiert). Wenn du mal Annotation willst: `swappy` zur
        # NixOS-Config hinzufügen und auf `screenshotFreeze` / `screenshot`
        # zurück switchen.
        "$mod SHIFT, S, global, caelestia:screenshotFreezeClip"                              # 4.11 — Region freeze → Clipboard
        "$mod SHIFT ALT, S, global, caelestia:screenshotClip"                                # Region live → Clipboard
        "$mod ALT, R, exec, caelestia record -s"                                             # Record with sound
        "CTRL ALT, R, exec, caelestia record"                                                # Record screen
        "$mod SHIFT ALT, R, exec, caelestia record -r"                                       # Record region

        # ── Alternate paste (Marius Bonus) ───────────────────────
        "CTRL SHIFT ALT, V, exec, sh -c 'sleep 0.5s && ydotool type -d 1 \"$(cliphist list | head -1 | cliphist decode)\"'"
        # Alt+V: convert image-clipboard → file path in clipboard
        # (Skript-Definition oben im let-block). User danach Ctrl+V.
        "ALT, V, exec, ${cc-paste-image}/bin/cc-paste-image"

        # ── Testing ──────────────────────────────────────────────
        "$mod ALT, F12, exec, notify-send -u low -i dialog-information-symbolic 'Test notification' \"Here's a really long message to test truncation and wrapping\\nYou can middle click or flick this notification to dismiss it!\" -a 'Shell' -A 'Test1=I got it!' -A 'Test2=Another action'"
      ]
      # ── Power modes ────────────────────────────────────────────
      # Five HP-equivalent modes (Power Saver / Quiet / Cool / Smart Sense /
      # Performance). F1..F5 ordered ascending by system performance — F1 is
      # the weakest, F5 the strongest. $mod+P cycles to the next stronger mode
      # (wraps at the top). Only wired in when services.powerModes is enabled
      # at the system level — keeps this hm-module portable to hosts that
      # don't ship the engine. See hosts/nixos-diego/power-modes.nix.
      ++ lib.optionals (osConfig.services.powerModes.enable or false) [
        "$mod SHIFT, F1, exec, power-mode set power-saver"
        "$mod SHIFT, F2, exec, power-mode set quiet"
        "$mod SHIFT, F3, exec, power-mode set cool"
        "$mod SHIFT, F4, exec, power-mode set smart-sense"
        "$mod SHIFT, F5, exec, power-mode set performance"
        "$mod, P, exec, power-mode cycle"
      ]
      # ── Gaming Mode ────────────────────────────────────────────
      # SteamOS muscle memory: one-key access to Gaming Mode. SUPER+G
      # switches into the gamescope session (Steam Deck UI) via
      # steamosctl — ADR-0005 picked jovian.steam.autoStart=false so
      # Hyprland stays the default boot, and steamosctl is the bridge
      # without re-login. Return path is the Steam Power Menu →
      # "Switch to Desktop" (wired up by ADR-0011's oneshot).
      #
      # SUPER+SHIFT+G keeps donvini's "Frage 4.4" Steam-in-desktop
      # launcher reachable on jovian hosts — SHIFT escalates from
      # "go gaming" to "no, I want Steam *here* in Hyprland". Non-jovian
      # hosts keep donvini's original $mod, G binding (block below).
      ++ lib.optionals (osConfig.jovian.steam.enable or false) [
        # Plan-0003 F6: optional Bluetooth pre-disconnect before SUPER+G.
        # When diego.gaming.disconnectBluetoothBeforeSwitch is true, drop any
        # connected A2DP/HFP devices first so BlueZ's synchronous teardown
        # isn't on the session-switch critical path. With no connected
        # devices, bluetoothctl disconnect exits 1 silently — the `;` (not
        # `&&`) keeps the steamosctl call unconditional. let-in-list verified
        # via nix-instantiate --eval --strict 2026-05-17 23:35.
        (let
          cmd =
            if (osConfig.diego.gaming.disconnectBluetoothBeforeSwitch or false)
            then "${pkgs.bluez}/bin/bluetoothctl disconnect; steamosctl switch-to-game-mode"
            else "steamosctl switch-to-game-mode";
        in "$mod, G, exec, ${cmd}")
        "$mod SHIFT, G, exec, mangohud steam"                                                # 4.4 — Steam in desktop (escalation)
      ]
      ++ lib.optionals (!(osConfig.jovian.steam.enable or false)) [
        "$mod, G, exec, mangohud steam"                                                      # 4.4 — Steam with MangoHud (donvini default)
      ];

      # Repeat-fähige Bindings
      binde = [
        "$mod, Page_Up, workspace, -1"
        "$mod, Page_Down, workspace, +1"
      ];

      bindm = [
        "$mod, mouse:272, movewindow"
        "$mod, mouse:273, resizewindow"
        "$mod, X, resizewindow"
      ];

      bindle = [
        # Tier 3: volumeStep = 10% (Marius statt donvini's 6%)
        ", XF86AudioRaiseVolume, exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ 0; wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 10%+"
        ", XF86AudioLowerVolume, exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ 0; wpctl set-volume @DEFAULT_AUDIO_SINK@ 10%-"
      ];

      bindl = [
        ", XF86AudioMute, exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"
        ", XF86AudioMicMute, exec, wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"
      ];


      # ──────────────────────────────────────────────────────────
      # Window Rules — Special Workspace Routing (Marius pattern)
      # Hyprland 0.54+ uses "windowrule v3" syntax: effects (e.g. `workspace`)
      # take a space-separated value, match properties are prefixed `match:`.
      # ──────────────────────────────────────────────────────────
      windowrule = [
        # Communication (Frage 4.7 — erweitert um Signal + Telegram am 2026-05-14)
        "workspace special:communication, match:class ^(discord|equibop|vesktop|whatsapp|Signal|org\\.telegram\\.desktop|TelegramDesktop)$"
        # Sysmon
        "workspace special:sysmon, match:class ^(btop)$"
      ];
    };
  };
}
