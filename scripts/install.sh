#!/bin/zsh
# Builds Penknife (Release), signs it with the local self-signed certificate and installs it
# in /Applications. The stable signature keeps macOS privacy permissions between builds.
# Create the certificate once: a code-signing certificate named "Penknife Local Signing"
# in the login keychain (see docs/DECISIONS.md). Never use an "Apple Development" one.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${PENKNIFE_SIGN_IDENTITY:-Penknife Local Signing}"
APP=build/Build/Products/Release/Penknife.app

xcodebuild -quiet -project Penknife.xcodeproj -scheme Penknife -configuration Release \
  -derivedDataPath build CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build

# Sign the product before copying it (re-signing the copy in /Applications breaks launch).
codesign --force --options runtime --sign "$IDENTITY" \
  --entitlements Penknife.entitlements "$APP"
codesign --verify --strict "$APP"

osascript -e 'tell application id "io.github.alexl-l.Penknife" to quit' 2>/dev/null || true
pkill -x Penknife 2>/dev/null || true
sleep 1
rm -rf /Applications/Penknife.app
ditto "$APP" /Applications/Penknife.app
open -g -a /Applications/Penknife.app
sleep 2
pgrep -x Penknife >/dev/null && echo "Penknife running" || { echo "Penknife did not start"; exit 1; }
