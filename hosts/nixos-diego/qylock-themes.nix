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
#   - `osu`, `osumania`, `ninja_gaiden`, `star-rail`, `Genshin`, `R1999_2`
#     — Plan-0017: dropped so every pooled theme cleanly supports the
#     single-Enter → fingerprint flow (game-gate / empty-Enter login-guard /
#     two-step reveal). See the per-theme reasons at the exclusion list in
#     installPhase below.
#
# Effective pool: 23 themes — all verified single-Enter login + working
# touchpad cursor + (via the wrapper PAM-info overlay) a visible "Place finger
# on sensor" prompt.
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
      # Plan-0017 — six themes excluded so EVERY pooled theme cleanly supports
      # the "Enter on empty password → fingerprint" flow with a single Enter
      # plus a working touchpad cursor (Marius's call 2026-05-31: drop the
      # offenders rather than carry per-theme login patches). Verified via a
      # 3-agent adversarial sweep of all sub-themes' Main.qml.
      #
      #   osu, osumania      — rhythm-game GATE. Both compute
      #     `gameMode: config.gameMode !== "menu"`; under this wrapper `config`
      #     is the EMPTY wrapper theme.conf, so `config.gameMode` is undefined
      #     → `undefined !== "menu"` is true → gameMode defaults to "game". At
      #     the login screen `doAction()` then resolves to `showingDiff = true`
      #     (difficulty selector) instead of `doLogin()`, so Enter shows a game
      #     instead of logging in — breaking BOTH password and fingerprint.
      #   ninja_gaiden       — `doLogin()` wraps its sole sddm.login() in
      #     `if (pwInput.text !== "")` → empty-Enter never arms fprintd.
      #   star-rail          — `doLogin()` is `if (passIn.text === "")
      #     { forceActiveFocus } else { sddm.login }` → empty-Enter only
      #     refocuses, never arms fprintd.
      #   Genshin, R1999_2   — two-step reveal-gate (loginFormVisible /
      #     interactionMode default false); the FIRST Enter only unveils the
      #     form, so the clean single-Enter fingerprint flow doesn't start.
      #
      # Reversibility: delete a theme's line below → next switch re-adds it to
      # the pool (osu/osumania/ninja_gaiden/star-rail would then need their
      # login guard patched; Genshin/R1999_2 would be two-step again).
      [ "$theme" = "osu" ] && continue
      [ "$theme" = "osumania" ] && continue
      [ "$theme" = "ninja_gaiden" ] && continue
      [ "$theme" = "star-rail" ] && continue
      [ "$theme" = "Genshin" ] && continue
      [ "$theme" = "R1999_2" ] && continue
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

        # (Plan-0013 F1.1 osumania one-liner-MouseArea fix-up removed in
        # Plan-0017: osumania is no longer in the pool, and it was the only
        # theme using the single-line `// Wayland Fix` variant. All 27
        # remaining themes carry the multi-line `// Wayland Cursor Fix` block
        # that the F1 sed above already patches.)

        # (Plan-0013 F4 per-theme onInformationMessage sed REMOVED in Plan-0017.
        # It only matched SINGLE-LINE onLoginFailed handlers, so it reached just
        # ~18/27 themes — the multi-line themes (dog-samurai, enfield, forest,
        # girl-coffee, last-of-us, pixel-dusk-city, winter, …) silently dropped
        # SDDM's PAM_TEXT_INFO "Place finger on sensor". Plan-0017 replaces it
        # with ONE theme-independent overlay in the qylock-random wrapper
        # Main.qml (see below: Connections{target:sddm}+fpHint), which renders
        # the prompt on EVERY sub-theme. Single mechanism, full coverage.)
      fi
    done

    # Plan-0017 — Build-time assertions: provable coverage of the two UX
    # guarantees on every pooled theme (click-through + a visible Wayland
    # cursor), plus drift tripwires. A future `nix flake update` of the pinned
    # qylock rev that breaks a sed pattern, changes the theme set, or
    # re-introduces an excluded theme then FAILS the build loudly instead of
    # shipping a silently-broken greeter. Watch: Repology RSS for qylock + the
    # OPERATIONS.md re-pin checklist (re-audit login guards + cursor per rev).
    #
    # (The old F1.2 onInformationMessage per-theme count is gone — that signal
    # is now rendered by the qylock-random wrapper overlay, asserted separately
    # after the wrapper is generated, below.)
    accept_ok=0
    cursor_ok=0
    total=0
    for d in "$out/share/sddm/themes/"*/; do
      name=$(basename "$d")
      [ "$name" = "qylock-random" ] && continue
      total=$((total+1))
      if grep -q "acceptedButtons: Qt.NoButton" "$d/Main.qml" 2>/dev/null; then
        accept_ok=$((accept_ok+1))
      fi
      if grep -q "cursorShape:.*Qt\.ArrowCursor" "$d/Main.qml" 2>/dev/null; then
        cursor_ok=$((cursor_ok+1))
      fi
    done
    echo "Plan-0017: pool=$total themes; acceptedButtons(click-through)=$accept_ok; cursorShape(visible cursor)=$cursor_ok"
    if [ "$accept_ok" -lt "$total" ]; then
      echo "FAIL: $((total - accept_ok)) themes missed the acceptedButtons:Qt.NoButton patch — F1 sed drift; greeter clicks would be eaten" >&2
      exit 1
    fi
    if [ "$cursor_ok" -lt "$total" ]; then
      echo "FAIL: $((total - cursor_ok)) themes lack a cursorShape Qt.ArrowCursor claim — Wayland cursor would be invisible" >&2
      exit 1
    fi
    # Drift tripwire #1: the six Plan-0017-excluded themes must NOT be pooled.
    for forbidden in osu osumania ninja_gaiden star-rail Genshin R1999_2; do
      if [ -d "$out/share/sddm/themes/$forbidden" ]; then
        echo "FAIL: excluded theme '$forbidden' present in pool — exclusion drift (qylock re-pin re-introduced it?)" >&2
        exit 1
      fi
    done
    # Drift tripwire #2: the pinned qylock rev yields exactly 23 pooled themes.
    # A different count means the upstream theme set changed — re-audit every
    # NEW theme for an empty-Enter login guard AND a login-screen cursor claim
    # before trusting the pool (Plan-0017 §sweep methodology).
    if [ "$total" -ne 23 ]; then
      echo "FAIL: pool has $total themes, expected 23 — qylock rev changed; re-audit new/removed themes (login guard + cursor) per OPERATIONS.md" >&2
      exit 1
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

        // Plan-0017 — universal PAM-info overlay. Renders fprintd's
        // PAM_TEXT_INFO ("Place finger on sensor"), delivered via SDDM's
        // informationMessage signal, at the WRAPPER level so the hint shows on
        // EVERY pooled sub-theme — including the multi-line themes the old
        // per-theme F4 sed could not reach. The sddm object is an SDDM greeter
        // root-context property visible here as well as inside the Loaded
        // sub-theme. Qt signals are multicast, so a sub-theme with its own
        // onInformationMessage still receives it too — this handler is purely
        // additive. Verified SAFE-AS-IS by adversarial review (no binding
        // loop; z:9999 paints over the Loader; signal API confirmed against
        // SDDM 0.21 shipped themes maldives/maya/elarun).
        Connections {
            target: typeof sddm !== "undefined" ? sddm : null
            function onInformationMessage(message) { fpHint.text = message ? message : "" }
            function onLoginFailed() { fpHint.text = "" }
            function onLoginSucceeded() { fpHint.text = "" }
        }
        Rectangle {
            id: fpHintBg
            z: 9999
            visible: fpHint.text.length > 0
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 80
            width: fpHint.implicitWidth + 48
            height: fpHint.implicitHeight + 28
            radius: 10
            color: "#cc000000"
            border.color: "#40ffffff"
            border.width: 1
            Text {
                id: fpHint
                anchors.centerIn: parent
                text: ""
                color: "white"
                font.pixelSize: 22
                font.bold: true
                style: Text.Outline
                styleColor: "black"
                horizontalAlignment: Text.AlignHCenter
            }
        }
    }
    EOF

    # Plan-0017 — assert the wrapper carries the universal PAM-info overlay.
    # If a future edit drops it, the "Place finger on sensor" prompt would go
    # invisible on every theme again — fail the build loudly instead.
    if ! grep -q "function onInformationMessage" "$out/share/sddm/themes/qylock-random/Main.qml"; then
      echo "FAIL: qylock-random wrapper is missing the onInformationMessage overlay — fingerprint prompt would be invisible pool-wide" >&2
      exit 1
    fi

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
