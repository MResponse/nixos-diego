{ stdenvNoCC, fetchFromGitHub, kdePackages, gst_all_1, lib }:

# Qylock SDDM theme bundle (Plan-0004 Phase 1, ADR-0026).
#
# Bundles all qylock SDDM themes (Darkkal44/qylock @ pinned commit) plus a
# wrapper theme `qylock-random` that, at QML load time, picks a random
# sub-theme via `Loader { source: "../<picked>/Main.qml" }`. Each greeter
# spawn rolls a fresh pick.
#
# Excluded from the pool:
#   - `clockwork/` — subdirectory-themes need flatten-special-case logic,
#     deferred per Plan-0004 §5.5.
#   - `nier-automata` — requires FOT-Rodin Pro DB.otf (copyrighted, not in
#     repo). Deferred per Plan-0004 §5.5.
#
# Effective pool: ~31 themes (13 STATIC + 18 VIDEO).
#
# Codec-surface caveat: VIDEO-themes (pixel-rainyroom, forest, …) use
# `bg.mp4` via QtMultimedia + gst-libav. gst MP4 parser CVE-family runs
# pre-login as sddm user on every greeter spawn that rolls a video theme.
# Bewusst akzeptiert per ADR-0026 (random-pool ist Marius's explizites
# Goal, see Plan-0004 §0 Goal 1).
#
# LICENSE: GPL-3.0 (verifiziert 2026-05-17 via curl LICENSE-Header).
# AUDIT 2026-05-17: themes/*/*.qml gelesen — keine Process.start, keine
# XHR-Network-Calls auf externe Hosts. Bei Re-Pin: diff zum vorigen rev
# lesen + ADR-0026-Nachtrag.

stdenvNoCC.mkDerivation {
  pname = "qylock-sddm-random-pool";
  version = "0-unstable-2026-05-17";

  src = fetchFromGitHub {
    owner = "Darkkal44";
    repo  = "qylock";
    rev   = "6946b53626b4f3c1507ae9a78c287411df5fb36c";
    sha256 = "0kdy4w7az0ygmv3yf92xsyrflak52lm3prp8lickwk207y3qgm7g";
  };

  # qylock provides themes as plain files (no build step). stdenvNoCC + a
  # pure installPhase keeps the closure free of compilers/build deps.
  dontBuild = true;
  dontConfigure = true;
  # Data-only derivation: no binaries to wrap. The qt6 Setup-Hook pulls in
  # qtPreHook which insists on either wrapQtAppsHook or this flag.
  dontWrapQtApps = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/share/sddm/themes

    # Bundle every top-level theme directory except the excluded ones.
    for theme_path in "$src/themes/"*/; do
      theme=$(basename "$theme_path")
      [ "$theme" = "clockwork" ] && continue
      [ "$theme" = "nier-automata" ] && continue
      mkdir -p "$out/share/sddm/themes/$theme"
      cp -r "$theme_path"/. "$out/share/sddm/themes/$theme/"

      # Force QtVersion=6. qylock-Themes liefern QtVersion nicht zuverlaessig
      # — Default-Fallback waere Qt5 (langsamer Spawn + Mixed-Stack-Risiko).
      meta="$out/share/sddm/themes/$theme/metadata.desktop"
      if [ -f "$meta" ]; then
        if grep -q '^QtVersion=' "$meta"; then
          sed -i 's/^QtVersion=.*/QtVersion=6/' "$meta"
        else
          echo "QtVersion=6" >> "$meta"
        fi
      fi
    done

    # Build the pool list from what we just bundled (skip the wrapper-self).
    pool_themes=()
    for d in "$out/share/sddm/themes/"*/; do
      name=$(basename "$d")
      [ "$name" = "qylock-random" ] && continue
      pool_themes+=("$name")
    done

    # JS array literal: "field","pixel-rainyroom",...,"wuwa"
    pool_json=$(printf '"%s",' "''${pool_themes[@]}" | sed 's/,$//')

    # Generate the wrapper theme.
    mkdir -p "$out/share/sddm/themes/qylock-random"

    cat > "$out/share/sddm/themes/qylock-random/metadata.desktop" <<EOF
    [SddmGreeterTheme]
    Name=qylock-random
    Description=Qylock random theme pool (rolls per greeter spawn)
    Author=Plan-0004 wrapper + Darkkal44/qylock
    Type=sddm-theme
    Version=1.0
    Website=https://github.com/Darkkal44/qylock
    Screenshot=
    MainScript=Main.qml
    ConfigFile=theme.conf
    QtVersion=6
    EOF

    cat > "$out/share/sddm/themes/qylock-random/theme.conf" <<EOF
    [General]
    # Wrapper has no own config — sub-themes load their own visuals.
    EOF

    # The wrapper's Main.qml. NOTE on context propagation: SDDM injects
    # `sddm`, `config`, `userModel`, `sessionModel`, `keyboard` as QML
    # root-context properties. Singletons (sddm, userModel) propagate
    # cleanly via Loader. `config` is theme-specific (loaded from THIS
    # theme's theme.conf, which is empty above) — sub-themes that read
    # `config.<key>` will see undefined values and must use defaults.
    # Plan-0004 §7 Risk #4b: untested on Diego until first rebuild.
    cat > "$out/share/sddm/themes/qylock-random/Main.qml" <<EOF
    import QtQuick
    import QtQuick.Controls

    Rectangle {
        id: root
        width: Screen.width
        height: Screen.height
        color: "black"

        // Plan-0005 F1 — Wayland Cursor Fix at wrapper root.
        // Repliziert qylock-Maintainer-Fix (commit 9b556ec, 2026-05-12)
        // einen Layer hoeher: Qt6's pointer_enter triggert updateCursor()
        // das window()->cursor() liest. Wenn kein Item den Cursor gesetzt
        // hat, sendet Qt set_cursor(nullptr) = cursor versteckt. Diese
        // MouseArea setzt window-level cursor via Item-Tree-Walk waehrend
        // Scene-Graph-Sync (BEVOR pointer_enter). z: -1 + Qt.NoButton
        // verhindern Event-Stealing von Sub-Theme-Items.
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.ArrowCursor
            z: -1
            acceptedButtons: Qt.NoButton
        }

        readonly property var pool: [$pool_json]
        readonly property string picked: pool[Math.floor(Math.random() * pool.length)]

        Component.onCompleted: {
            console.log("qylock-random: picked", picked);
            themeLoader.source = "../" + picked + "/Main.qml";
        }

        Loader {
            id: themeLoader
            anchors.fill: parent
            onStatusChanged: {
                if (status === Loader.Error) {
                    console.error("qylock-random: failed to load", source);
                }
            }
        }
    }
    EOF

    runHook postInstall
  '';

  # SDDM-Qt6 greeter dependencies. qtmultimedia + gst-* are required for
  # the VIDEO-themes in the pool (pixel-rainyroom et al use `bg.mp4` via
  # QtMultimedia.MediaPlayer). NixOS propagates these into the SDDM Qt env
  # via `services.displayManager.sddm.extraPackages = [ qylockThemes ]`.
  propagatedBuildInputs = with kdePackages; [
    qtdeclarative
    qt5compat
    qtsvg
    qtmultimedia
  ] ++ (with gst_all_1; [
    gstreamer
    gst-plugins-base
    gst-plugins-good
    gst-plugins-bad
    gst-plugins-ugly
    gst-libav
  ]);

  meta = {
    description = "Qylock SDDM themes (random-pool wrapper for Diego)";
    homepage = "https://github.com/Darkkal44/qylock";
    license = lib.licenses.gpl3Plus;
    platforms = lib.platforms.linux;
  };
}
