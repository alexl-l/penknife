#!/bin/zsh
# Builds Penknife (Release), signs it with the local self-signed certificate and installs it
# in /Applications. The stable signature keeps macOS privacy permissions between builds.
# Create the certificate once: a code-signing certificate named "Penknife Local Signing"
# in the login keychain (see docs/DECISIONS.md). Never use an "Apple Development" one.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Build/Products/Release/Penknife.app
# Build number = number of commits, so every committed change gets a higher one with no
# file to edit. The version (1.0, 1.1…) is MARKETING_VERSION in the project; see CHANGELOG.md.
BUILD=$(git rev-list --count HEAD)

xcodebuild -quiet -project Penknife.xcodeproj -scheme Penknife -configuration Release \
  -derivedDataPath build CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  CURRENT_PROJECT_VERSION="$BUILD" build

# Sign the product before copying it (re-signing the copy in /Applications breaks launch).
scripts/sign-app.sh "$APP"

osascript -e 'tell application id "io.github.alexl-l.Penknife" to quit' 2>/dev/null || true
pkill -x Penknife 2>/dev/null || true
sleep 1
rm -rf /Applications/Penknife.app
ditto "$APP" /Applications/Penknife.app
open -g -a /Applications/Penknife.app
sleep 2
pgrep -x Penknife >/dev/null && echo "Penknife $(defaults read "$PWD/$APP/Contents/Info" CFBundleShortVersionString) ($BUILD) running" || { echo "Penknife did not start"; exit 1; }
