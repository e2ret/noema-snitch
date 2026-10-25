#!/bin/bash
# Builds the DMG and app zip for the version in Resources/Info.plist, commits the
# version bump, tags vX.Y.Z, pushes and publishes a GitHub release.
#   ./scripts/release.sh            # notes from scripts/release-notes-X.Y.Z.md
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
TAG="v$VERSION"
NOTES="scripts/release-notes-$VERSION.md"
[ -f "$NOTES" ] || { echo "Нет файла с описанием: $NOTES"; exit 1; }
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { echo "Тег $TAG уже существует"; exit 1; }

./scripts/make-dmg.sh
DMG="build/NoemaSnitch-$VERSION.dmg"
ZIP="build/NoemaSnitch-$VERSION-app.zip"
rm -f "$ZIP"
(cd build && ditto -c -k --keepParent "Noema Snitch.app" "$(basename "$ZIP")")

# Only project files: never third-party apps kept in the folder for analysis.
git add Resources/Info.plist "$NOTES" scripts/release.sh
if git status --short | grep -E '^[AM].*\.app/' ; then
    echo "В коммит попал .app — остановлено."; exit 1
fi
git commit -m "Release $VERSION" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git tag -a "$TAG" -m "Noema Snitch $VERSION"
git push --follow-tags

gh release create "$TAG" "$DMG" "$ZIP" --title "Noema Snitch $VERSION" --notes-file "$NOTES" --latest
echo "Готово: https://github.com/e2ret/noema-snitch/releases/tag/$TAG"
