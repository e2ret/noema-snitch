#!/bin/bash
# Builds build/Noema Snitch.app (app + root helper) with an ad-hoc signature.
# No Apple Developer account needed. Uses swiftc directly so it also works when
# SwiftPM's manifest library is broken (mixed Command Line Tools installs).
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=".build/swiftc"
mkdir -p "$OUT"
FLAGS=(-swift-version 5 -target arm64-apple-macos14.0 -O)

# Mixed CLT 15.x/16.x installs leave a stale usr/include/swift/module.modulemap
# that redefines SwiftBridging; hide it from the compiler with a VFS overlay.
CLT_SWIFT_INCLUDE="$(xcode-select -p)/usr/include/swift"
if [ -f "$CLT_SWIFT_INCLUDE/module.modulemap" ] && [ -f "$CLT_SWIFT_INCLUDE/bridging.modulemap" ]; then
    : > "$OUT/empty.modulemap"
    cat > "$OUT/overlay.yaml" <<EOF
{ "version": 0, "case-sensitive": "false", "roots": [ { "type": "directory",
  "name": "$CLT_SWIFT_INCLUDE", "contents": [ { "type": "file",
  "name": "module.modulemap", "external-contents": "$PWD/$OUT/empty.modulemap" } ] } ] }
EOF
    FLAGS+=(-vfsoverlay "$OUT/overlay.yaml" -Xcc -ivfsoverlay -Xcc "$OUT/overlay.yaml")
fi

echo "Compiling NoemaShared…"
swiftc "${FLAGS[@]}" -parse-as-library -module-name NoemaShared \
    -emit-library -static -emit-module -emit-module-path "$OUT/NoemaShared.swiftmodule" \
    Sources/NoemaShared/*.swift -o "$OUT/libNoemaShared.a"

LINK=(-I "$OUT" -L "$OUT" -lNoemaShared)
echo "Compiling NoemaHelper…"
swiftc "${FLAGS[@]}" "${LINK[@]}" -module-name NoemaHelper \
    Sources/NoemaHelper/*.swift -o "$OUT/NoemaHelper"
echo "Compiling NoemaSnitch…"
swiftc "${FLAGS[@]}" "${LINK[@]}" -parse-as-library -module-name NoemaSnitch \
    $(find Sources/NoemaSnitch -name '*.swift') -o "$OUT/NoemaSnitch"

APP="build/Noema Snitch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OUT/NoemaSnitch" "$APP/Contents/MacOS/NoemaSnitch"
cp "$OUT/NoemaHelper" "$APP/Contents/Resources/NoemaHelper"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/Geo "$APP/Contents/Resources/Geo"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp scripts/install-helper.sh scripts/uninstall-helper.sh "$APP/Contents/Resources/"
for lproj in Resources/*.lproj; do
    plutil -lint -s "$lproj"/*.strings
    cp -R "$lproj" "$APP/Contents/Resources/"
done

codesign --force --sign "${SIGN_ID:--}" "$APP/Contents/Resources/NoemaHelper"
codesign --force --sign "${SIGN_ID:--}" "$APP"
echo "Built $APP"
