#!/bin/bash
# Builds build/Clawd.app from Sources/ using only the command-line Swift toolchain.
#
#   ./build.sh              universal app (Apple Silicon + Intel), signed ad hoc for this Mac
#   ./build.sh --release    also zips it into dist/Clawd-<version>.zip
#
# To sign a release for other Macs, set CLAWD_SIGN_IDENTITY to your "Developer ID Application: …"
# identity. Also set CLAWD_NOTARY_PROFILE to a `xcrun notarytool store-credentials` profile name to
# notarize and staple the release, so it opens without a Gatekeeper warning.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Clawd"
BUILD="build"
APP="$BUILD/$APP_NAME.app"
BIN="$APP/Contents/MacOS/$APP_NAME"
MIN_OS="13.0"
RELEASE=0
[[ "${1:-}" == "--release" ]] && RELEASE=1

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling..."
for arch in arm64 x86_64; do
    swiftc -O -target "$arch-apple-macos$MIN_OS" Sources/*.swift -framework AppKit -o "$BUILD/$APP_NAME-$arch"
done
lipo -create "$BUILD/$APP_NAME-arm64" "$BUILD/$APP_NAME-x86_64" -output "$BIN"
rm -f "$BUILD/$APP_NAME-arm64" "$BUILD/$APP_NAME-x86_64"
cp Info.plist "$APP/Contents/Info.plist"

echo "Rendering icon..."
ICONSET="$BUILD/AppIcon.iconset"
rm -rf "$ICONSET"
"$BIN" --render-icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
"$BIN" --render-preview "$BUILD/preview.png"
"$BIN" --render-preview-dark "$BUILD/preview-dark.png"

if [[ -n "${CLAWD_SIGN_IDENTITY:-}" ]]; then
    echo "Signing as $CLAWD_SIGN_IDENTITY..."
    codesign --force --options runtime --timestamp --entitlements Clawd.entitlements \
        --sign "$CLAWD_SIGN_IDENTITY" "$APP"
else
    codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi
echo "Built $APP"

if [[ $RELEASE == 1 ]]; then
    VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
    mkdir -p dist
    ZIP="dist/$APP_NAME-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    if [[ -n "${CLAWD_SIGN_IDENTITY:-}" && -n "${CLAWD_NOTARY_PROFILE:-}" ]]; then
        echo "Notarizing..."
        xcrun notarytool submit "$ZIP" --keychain-profile "$CLAWD_NOTARY_PROFILE" --wait
        xcrun stapler staple "$APP"
        rm -f "$ZIP"
        ditto -c -k --keepParent "$APP" "$ZIP"
    elif [[ -z "${CLAWD_SIGN_IDENTITY:-}" ]]; then
        echo "Note: this zip is only ad-hoc signed; other Macs will block it until it is signed and notarized."
    fi
    echo "Packaged $ZIP"
fi
