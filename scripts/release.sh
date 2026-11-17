#!/bin/zsh
# Publishes a new version (R-17): universal build (most Touch Bar Macs are Intel), local
# signature, zip, Sparkle appcast (signed with the EdDSA key in this Mac's Keychain) and a
# GitHub release. Before running: bump MARKETING_VERSION, add the CHANGELOG section,
# commit everything. The appcast goes live when docs/appcast.xml is pushed (GitHub Pages).
# Usage: scripts/release.sh            (prepares everything, uploads nothing)
#        scripts/release.sh --publish  (also creates the GitHub release; then push main)
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -z "$(git status --porcelain)" ]] || { echo "Commit everything first"; exit 1; }
BUILD=$(git rev-list --count HEAD)
VERSION=$(sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' Penknife.xcodeproj/project.pbxproj | head -1)
TAG="v$VERSION"
OUT=build/release/$TAG
APP=build/Build/Products/Release/Penknife.app
SPARKLE_BIN=build/SourcePackages/artifacts/sparkle/Sparkle/bin
grep -q "^## $VERSION " CHANGELOG.md || { echo "No CHANGELOG section for $VERSION"; exit 1; }

xcodebuild -quiet -project Penknife.xcodeproj -scheme Penknife -configuration Release \
  -derivedDataPath build -destination 'generic/platform=macOS' ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CURRENT_PROJECT_VERSION="$BUILD" build
scripts/sign-app.sh "$APP"

rm -rf "$OUT"; mkdir -p "$OUT"
ZIP="$OUT/Penknife-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

# Release notes: the CHANGELOG section, shown in Sparkle's window and on the release page.
awk -v v="## $VERSION " 'index($0, v) == 1 {on = 1; next} /^## / {on = 0} on' CHANGELOG.md > "$OUT/notes.md"
{
  echo "<ul>"
  sed -n 's/^- \(.*\)/<li>\1<\/li>/p' "$OUT/notes.md"
  echo "</ul>"
} > "$OUT/Penknife-$VERSION.html"

"$SPARKLE_BIN/generate_appcast" --embed-release-notes \
  --download-url-prefix "https://github.com/alexl-l/penknife/releases/download/$TAG/" \
  -o docs/appcast.xml "$OUT"
echo "Ready: $ZIP, docs/appcast.xml (build $BUILD)"

if [[ "${1:-}" == "--publish" ]]; then
  {
    cat "$OUT/notes.md"
    echo
    echo "**Install:** unzip, move Penknife to Applications, open it. The first time, macOS asks: System Settings → Privacy & Security → Open Anyway. No Open Anyway button, or the warning keeps coming back (Macs managed by a company or school)? Run \`xattr -dr com.apple.quarantine /Applications/Penknife.app\` in Terminal and open it again; on a work Mac, ask your IT team first. Later versions update from the app (menu → Check for Updates…)."
  } > "$OUT/release-notes.md"
  gh release create "$TAG" "$ZIP" --title "Penknife $VERSION" --notes-file "$OUT/release-notes.md"
  echo "Now commit docs/appcast.xml and push main so the update goes live."
fi
