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

      # Plan-0012 F1 — patch sub-theme MouseArea acceptedButtons (ADR-0030).
      # qylock-upstream commit 9b556ec (Wayland Cursor Fix) inserted
      #   MouseArea { anchors.fill: parent; cursorShape: Qt.ArrowCursor; z: -1 }
      # als FIRST CHILD jedes Sub-Theme Root-Rectangle, OHNE
      # `acceptedButtons: Qt.NoButton`. Default `acceptedButtons = Qt.LeftButton`
      # plus anchors.fill: parent + identisches bounding-rect zu Layout-Children
      # = Qt6-hit-test-Edge-Case wo MouseArea Klicks auf Session-Dropdown /
      # Login-Button konsumiert. Plan-0005 F1 fixte nur den qylock-random
      # Wrapper, nicht die 31 Sub-Themes — Marius's "SDDM-Maus-tot"-Symptom.
      #
      # sed-Pattern: matche jeden Block "// Wayland Cursor Fix" bis schliessende
      # `}`-Zeile, und nach der `cursorShape:.*Qt.ArrowCursor`-Zeile
      # `acceptedButtons: Qt.NoButton` einfuegen.
      # `|| true` schluckt Fehler falls Pattern in einem Theme nicht greift
      # (verify via Plan-Test-Step).
      #
      # Quelle: https://doc.qt.io/qt-6/qml-qtquick-mousearea.html
      #   "In order to only set a mouse cursor shape for a region without
      #   reacting to mouse events set the acceptedButtons to none."
      main_qml="$out/share/sddm/themes/$theme/Main.qml"
      if [ -f "$main_qml" ]; then
        sed -i '/\/\/ Wayland Cursor Fix/,/^[[:space:]]*}[[:space:]]*$/{
          /cursorShape:.*Qt\.ArrowCursor/a\        acceptedButtons: Qt.NoButton
        }' "$main_qml" || true

        # Plan-0013 F1.1 — fix-up osumania theme variant. osumania nutzt
        # ein anderes Pattern als die anderen 28 Sub-Themes:
        #   - Comment: `// Wayland Fix` (statt `// Wayland Cursor Fix`)
        #   - MouseArea: one-liner statt multi-line
        # Plan-0012 F1 sed-Pattern hat osumania still uebersprungen.
        # Dieser sed-block matcht one-liner MouseArea OHNE acceptedButtons
        # und ergaenzt es. Idempotent: matcht nur wenn acceptedButtons
        # noch fehlt.
        sed -i \
          's|\(MouseArea { anchors\.fill: parent; cursorShape: Qt\.ArrowCursor;\)\( z: -1 }\)|\1 acceptedButtons: Qt.NoButton;\2|' \
          "$main_qml" || true

        # Plan-0013 F4 — inject onInformationMessage-Handler in Sub-Themes
        # mit SINGLE-LINE onLoginFailed. SDDM 0.21 sendet PAM_TEXT_INFO
        # ("Place finger on sensor") via informationMessage-Signal an QML;
        # qylock-Themes haben aktuell nur onLoginFailed-Handler und
        # verschlucken die Info-Message. Konsequenz: Marius am Greeter
        # sieht keine visuelle Indikation dass fprintd scharf ist.
        #
        # Pattern: nach jedem `function onLoginFailed(...) { ... }`-Line
        # (komplettes one-liner, abgeschlossen mit `}` am Zeilenende)
        # einen neuen `function onInformationMessage(message)`-Handler
        # appenden. Theme-Variant-Handling: themes nutzen entweder
        # errorMsg (field-Familie) oder errorMessage (enfield-Familie);
        # typeof-guard deckt beide ab. Bei drittem Variant (z.B. `status`-
        # Label) faellt die Message still durch — kein Crash, nur kein
        # Render.
        #
        # WICHTIG: Anchor muss SINGLE-LINE sein. Multi-line-Themes
        # (osumania, enfield, forest, ...) haben `function onLoginFailed() {`
        # mit Body auf folgenden Zeilen. Ein Match auf nur `function
        # onLoginFailed` ohne `}`-End-Anchor wuerde den neuen Handler
        # INSIDE den Body von onLoginFailed injecten → invalide QML.
        # Der Regex `function onLoginFailed.*\}[[:space:]]*$` matcht NUR
        # Zeilen die mit `}` enden — 18 von 29 Sub-Themes.
        #
        # Multi-line themes: F4-Handler wird NICHT injected. F1.2-Assert
        # produziert WARN (kein FAIL) — Marius sieht die "Place finger"
        # Message nur in 18/29 ≈ 62% der per-greeter-spawn gerollten
        # themes. Acceptable, da F4 ein UX-Enhancement ist (kein blocker).
        # Future Plan-0014/0015 koennte multi-line themes mit awk-state-
        # tracking adressieren.
        #
        # Quelle (SDDM canonical pattern): /nix/store/.../sddm-unwrapped-
        # 0.21.0/share/sddm/themes/maldives/Main.qml hat
        #   onInformationMessage: { errorMessage.text = message }
        # → confirmed signal-existence in shipped SDDM.
        sed -i -E '/function onLoginFailed\([^)]*\)[[:space:]]*\{.*\}[[:space:]]*$/{
          a\        function onInformationMessage(message) { if (typeof errorMsg !== "undefined") { errorMsg.text = message; } else if (typeof errorMessage !== "undefined") { errorMessage.text = message; } }
        }' "$main_qml" || true
      fi
    done

    # Plan-0013 F1.2 — Build-time-Assertion: prueft dass die qylock-
    # sed-Patches in ALLEN Sub-Themes greifen. Wenn ein qylock-upstream-
    # refactor das Pattern bricht, schlaegt der Build EXPLIZIT fehl statt
    # silently disfunctional zu sein.
    #
    # Watch-Mechanism:
    #   - bei `nix flake update` der qylock-Rev meldet Build patch-loss
    #   - Repology RSS + monthly Habitica-Reminder in OPERATIONS.md
    patched=0
    info_patched=0
    total=0
    for d in "$out/share/sddm/themes/"*/; do
      name=$(basename "$d")
      [ "$name" = "qylock-random" ] && continue
      total=$((total+1))
      if grep -q "acceptedButtons: Qt.NoButton" "$d/Main.qml" 2>/dev/null; then
        patched=$((patched+1))
      fi
      if grep -q "function onInformationMessage" "$d/Main.qml" 2>/dev/null; then
        info_patched=$((info_patched+1))
      fi
    done
    echo "Plan-0013 F1.2: $patched/$total qylock-themes have acceptedButtons-patch (F1+F1.1)"
    echo "Plan-0013 F1.2: $info_patched/$total qylock-themes have onInformationMessage-handler (F4)"
    if [ "$patched" -lt "$total" ]; then
      echo "FAIL: $((total - patched)) themes missed F1/F1.1 acceptedButtons-patch — investigate sed-pattern drift" >&2
      exit 1
    fi
    if [ "$info_patched" -lt "$total" ]; then
      echo "INFO: $((total - info_patched)) themes have multi-line onLoginFailed and skip F4 onInformationMessage-patch (PAM_TEXT_INFO will be invisible there). Expected: ~11 multi-line themes." >&2
      # NICHT fail — F4 ist UX-enhancement, kein blocker. Multi-line
      # themes haben strukturell anderen Anchor-Bedarf (awk-state-track
      # statt sed-pattern) — siehe Plan-0013 §F4-Comment.
    fi

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
