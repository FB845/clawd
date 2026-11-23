#!/bin/bash
# Builds build/Clawd.app from Sources/ using only the command-line Swift toolchain.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Clawd"
BUILD="build"
APP="$BUILD/$APP_NAME.app"
BIN="$APP/Contents/MacOS/$APP_NAME"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling..."
swiftc -O Sources/*.swift -framework AppKit -o "$BIN"
cp Info.plist "$APP/Contents/Info.plist"

echo "Rendering icon..."
ICONSET="$BUILD/AppIcon.iconset"
rm -rf "$ICONSET"
"$BIN" --render-icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
"$BIN" --render-preview "$BUILD/preview.png"
"$BIN" --render-preview-dark "$BUILD/preview-dark.png"

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
