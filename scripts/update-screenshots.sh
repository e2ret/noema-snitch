#!/bin/bash
# Refreshes docs/screenshots/*.png from the current build using the app's
# built-in demo data (--demo --snapshot). No Screen Recording permission needed.
#   ./scripts/update-screenshots.sh            # uses build/Noema Snitch.app
#   ./scripts/update-screenshots.sh --build    # rebuild the app first
set -euo pipefail
cd "$(dirname "$0")/.."

[ "${1:-}" = "--build" ] && ./scripts/build-app.sh
BIN="build/Noema Snitch.app/Contents/MacOS/NoemaSnitch"
[ -x "$BIN" ] || { echo "Нет $BIN — запустите с --build"; exit 1; }

DOMAIN=com.noema.snitch
SAVED_SECTION="$(defaults read $DOMAIN main.section 2>/dev/null || true)"
restore() {
    if [ -n "$SAVED_SECTION" ]; then defaults write $DOMAIN main.section "$SAVED_SECTION"
    else defaults delete $DOMAIN main.section 2>/dev/null || true; fi
}
trap restore EXIT

pkill -x NoemaSnitch 2>/dev/null && sleep 1 || true

# Largest / smallest PNG in a directory (by pixel area) = main window / alert panel.
pick() { # dir largest|smallest
    local best="" area cmp
    for f in "$1"/*.png; do
        [ -f "$f" ] || continue
        area=$(( $(sips -g pixelWidth "$f" | awk '/pixelWidth/{print $2}') * \
                 $(sips -g pixelHeight "$f" | awk '/pixelHeight/{print $2}') ))
        if [ -z "$best" ] || { [ "$2" = largest ] && [ $area -gt $cmp ]; } || \
           { [ "$2" = smallest ] && [ $area -lt $cmp ]; }; then best="$f"; cmp=$area; fi
    done
    echo "$best"
}

shoot() { # lang
    local out="build/screenshots/$1"
    rm -rf "$out"; mkdir -p "$out"
    defaults write $DOMAIN main.section monitor
    "$BIN" --demo --snapshot "$PWD/$out" --cycle-sections \
        -AppleLanguages "($1)" -monitor.showChart YES -monitor.showInspector YES >/dev/null 2>&1
    echo "$out"
}

RU=$(shoot ru)

cp "$(pick "$RU/monitor" largest)"   docs/screenshots/monitor.png
cp "$(pick "$RU/rules" largest)"     docs/screenshots/rules.png
cp "$(pick "$RU/settings" largest)"  docs/screenshots/settings.png
cp "$(pick "$RU" smallest)"          docs/screenshots/alert.png
for f in docs/screenshots/*.png; do sips -Z 1600 "$f" >/dev/null; done

echo "Готово: docs/screenshots обновлены (исходники — build/screenshots)."
