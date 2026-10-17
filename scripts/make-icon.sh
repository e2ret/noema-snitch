#!/bin/bash
# Renders scripts/make-icon.swift and packs Resources/AppIcon.icns.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=".build/icon"
rm -rf "$OUT"
mkdir -p "$OUT/AppIcon.iconset"

FLAGS=()
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

swiftc -swift-version 5 "${FLAGS[@]}" scripts/make-icon.swift -o "$OUT/make-icon"
"$OUT/make-icon" "$OUT/icon_1024.png"

for s in 16 32 128 256 512; do
    sips -z $s $s "$OUT/icon_1024.png" --out "$OUT/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d "$OUT/icon_1024.png" --out "$OUT/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$OUT/AppIcon.iconset" -o Resources/AppIcon.icns
cp "$OUT/icon_1024.png" docs/icon.png
echo "Wrote Resources/AppIcon.icns"
