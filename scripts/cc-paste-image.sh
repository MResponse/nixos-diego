#!/bin/sh
# Pipe an image from the Wayland clipboard (or newest Caelestia screenshot)
# into the focused window as a file path. Bound to Alt+V in Hyprland.

set -u

ts=$(date +%Y%m%d%H%M%S)
out="/tmp/cc-paste-${ts}.png"

if wl-paste --list-types 2>/dev/null | grep -q '^image/'; then
    wl-paste --type image/png > "$out" 2>/dev/null
fi

if [ ! -s "$out" ]; then
    cache="$HOME/.cache/caelestia/screenshots"
    latest=$(ls -t "$cache" 2>/dev/null | head -1)
    if [ -n "$latest" ] && [ -s "$cache/$latest" ]; then
        cp "$cache/$latest" "$out"
    fi
fi

if [ ! -s "$out" ]; then
    notify-send -u normal -i image-x-generic-symbolic \
        "cc-paste" "No image in clipboard or screenshot cache"
    exit 1
fi

# Small delay so the keybind release doesn't race with wtype
sleep 0.08
wtype -- "$out "
