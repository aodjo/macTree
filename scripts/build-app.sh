#!/bin/bash
# Builds MacTree.app into ./build (release).
#
# Signing: uses the first "Apple Development" identity in the keychain so that
# macOS keeps the Full Disk Access grant across rebuilds (an ad-hoc signature
# changes every build and the grant stops applying). Override with
# SIGN_IDENTITY="<name or SHA-1>", or SIGN_IDENTITY=- for ad-hoc.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=build/MacTree.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MacTree "$APP/Contents/MacOS/MacTree"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/*.lproj "$APP/Contents/Resources/"

if [ ! -f build/AppIcon.icns ] || [ scripts/make-icon.swift -nt build/AppIcon.icns ]; then
    rm -rf build/AppIcon.iconset
    swift scripts/make-icon.swift build/AppIcon.iconset
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# VERSION / BUILD_NUMBER (set by CI for tagged releases) override the Info.plist defaults.
if [ -n "${VERSION:-}" ]; then
    plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
fi
if [ -n "${BUILD_NUMBER:-}" ]; then
    plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
fi

IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development/ { print $2; exit }')
fi
IDENTITY="${IDENTITY:--}"
codesign --force --sign "$IDENTITY" "$APP"
if [ "$IDENTITY" = "-" ]; then
    echo "Built $APP (ad-hoc signed)"
else
    echo "Built $APP (signed: $(codesign -dv --verbose=2 "$APP" 2>&1 | awk -F= '/^Authority/ { print $2; exit }'))"
fi
