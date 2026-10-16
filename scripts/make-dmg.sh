#!/bin/bash
#
# Builds Horizon Notch (Release, Apple Silicon + Intel) and packs it into a
# disk image with a link to /Applications: build/HorizonNotch-<version>.dmg
#
# Optional environment:
#   SIGN_IDENTITY   Code signing identity, e.g. "Developer ID Application: Name (TEAMID)".
#                   Default: "FlowTools Local Signing" if present, otherwise ad hoc.
#   NOTARY_PROFILE  notarytool keychain profile (xcrun notarytool store-credentials).
#                   When set, the DMG is notarized and stapled, so it opens
#                   without any Gatekeeper warning. Needs a Developer ID identity.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="HorizonNotch"
BUILD_DIR="build/dmg"
PRODUCTS="$BUILD_DIR/dd/Build/Products/Release"

command -v xcodebuild >/dev/null || { echo "✗ Xcode fehlt"; exit 1; }

if [ -z "${SIGN_IDENTITY:-}" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q "FlowTools Local Signing"; then
  SIGN_IDENTITY="FlowTools Local Signing"
fi
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
echo "→ Signatur: $SIGN_IDENTITY"

SIGN_ARGS=(CODE_SIGN_IDENTITY="$SIGN_IDENTITY" CODE_SIGN_STYLE=Manual)
if [ -n "${NOTARY_PROFILE:-}" ]; then
  # Notarization requires the hardened runtime and a secure timestamp; the
  # entitlements keep calendar, location and AppleScript working under it.
  SIGN_ARGS+=(ENABLE_HARDENED_RUNTIME=YES "OTHER_CODE_SIGN_FLAGS=--timestamp"
              CODE_SIGN_ENTITLEMENTS=Support/HorizonNotch-Release.entitlements)
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
echo "→ Baue Release (arm64 + x86_64) …"
if ! xcodebuild -project HorizonNotch.xcodeproj -scheme HorizonNotch -configuration Release \
     -derivedDataPath "$BUILD_DIR/dd" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
     "${SIGN_ARGS[@]}" build > "$BUILD_DIR/build.log" 2>&1; then
  echo "✗ Bau fehlgeschlagen – Details in $BUILD_DIR/build.log"
  grep -E "error:" "$BUILD_DIR/build.log" | head -20 || tail -30 "$BUILD_DIR/build.log"
  exit 1
fi

APP="$PRODUCTS/$APP_NAME.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="build/$APP_NAME-$VERSION.dmg"
echo "✓ Gebaut: Version $VERSION"

# Disk image contents: the app and a shortcut to drag it onto.
STAGE="$BUILD_DIR/stage"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "Horizon Notch" -srcfolder "$STAGE" -fs HFS+ -format UDZO \
  -imagekey zlib-level=9 -ov "$DMG" > /dev/null
if [ "$SIGN_IDENTITY" != "-" ]; then
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
fi
echo "✓ DMG: $DMG"

if [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "→ Notarisiere (dauert ein paar Minuten) …"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  echo "✓ Notarisiert"
fi
