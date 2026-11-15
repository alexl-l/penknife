#!/bin/zsh
# Signs Penknife.app and the Sparkle parts inside it, innermost first, with the local
# self-signed certificate (Sparkle's helpers must carry the same signature as the app).
# Usage: scripts/sign-app.sh <path to Penknife.app>
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$1"
IDENTITY="${PENKNIFE_SIGN_IDENTITY:-Penknife Local Signing}"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign() { codesign --force --options runtime --sign "$IDENTITY" "$@"; }

[[ -x "$SPARKLE/Autoupdate" ]] || { echo "Sparkle layout changed: update scripts/sign-app.sh"; exit 1; }
# The XPC services are only for sandboxed apps; Penknife isn't, so they go (less to trust).
rm -rf "$SPARKLE/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
sign "$SPARKLE/Autoupdate"
sign "$SPARKLE/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign --entitlements Penknife.entitlements "$APP"
codesign --verify --deep --strict "$APP"
