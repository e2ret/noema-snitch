#!/bin/bash
# Builds the app and packs build/NoemaSnitch-<version>.dmg with an Applications link
# and install notes, ready to give to someone else.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh

APP="build/Noema Snitch.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
STAGE=".build/dmg"
DMG="build/NoemaSnitch-$VERSION.dmg"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp docs/INSTALL.txt "$STAGE/Установка — Install.txt"

hdiutil create -volname "Noema Snitch" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
