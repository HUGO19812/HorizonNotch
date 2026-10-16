#!/bin/bash
#
# Builds Horizon Notch (Release, Apple Silicon + Intel) and packs it into a
# disk image with a link to /Applications: build/HorizonNotch.dmg. The name
# has no version so ".../releases/latest/download/HorizonNotch.dmg" always
# points at the newest release.
#
# Optional environment:
#   SIGN_IDENTITY   Code signing identity, e.g. "Developer ID Application: Name (TEAMID)".
#                   Default: "FlowTools Local Signing" if present, otherwise ad hoc.
#   BUILD_NUMBER    Build number (CFBundleVersion); the app updates itself
#                   when GitHub has a higher one. CI passes the run number.
#   NOTARY_PROFILE  notarytool keychain profile (xcrun notarytool store-credentials).
#                   When set, the DMG is notarized and stapled, so it opens
#                   without any Gatekeeper warning. Needs a Developer ID identity.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="HorizonNotch"
BUILD_DIR="build/dmg.noindex"
PRODUCTS="$BUILD_DIR/dd/Build/Products/Release"

command -v xcodebuild >/dev/null || { echo "✗ Xcode fehlt"; exit 1; }

if [ -z "${SIGN_IDENTITY:-}" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q "FlowTools Local Signing"; then
  SIGN_IDENTITY="FlowTools Local Signing"
fi
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
echo "→ Signatur: $SIGN_IDENTITY"

SIGN_ARGS=(CODE_SIGN_IDENTITY="$SIGN_IDENTITY" CODE_SIGN_STYLE=Manual)
if [ -n "${BUILD_NUMBER:-}" ]; then
  SIGN_ARGS+=(CURRENT_PROJECT_VERSION="$BUILD_NUMBER")
fi
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

# Background picture, icon positions and volume icon via dmgbuild, which
# writes the Finder layout without needing Finder (works on CI too).
make_pretty_dmg() {
  local venv="$BUILD_DIR/venv"
  python3 -m venv "$venv" > /dev/null 2>&1 || return 1
  "$venv/bin/pip" install --quiet dmgbuild > /dev/null 2>&1 || return 1
  # One TIFF holding 1x and 2x, so the background is sharp on Retina.
  tiffutil -cathidpicheck Support/dmg/background.png Support/dmg/background@2x.png \
    -out "$BUILD_DIR/background.tiff" > /dev/null 2>&1 || return 1
  local icon_args=()
  [ -f "$APP/Contents/Resources/AppIcon.icns" ] && icon_args=(-D "icon=$APP/Contents/Resources/AppIcon.icns")
  "$venv/bin/dmgbuild" -s Support/dmg/dmgbuild-settings.py -D "app=$APP" \
    -D "background=$BUILD_DIR/background.tiff" ${icon_args[@]+"${icon_args[@]}"} "Horizon Notch" "$DMG"
}
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="build/$APP_NAME.dmg"
echo "✓ Gebaut: Version $VERSION"

rm -f "$DMG"
if make_pretty_dmg; then
  echo "✓ Gestaltete DMG"
else
  # Fallback: plain window with the app and a shortcut to drag it onto.
  echo "! dmgbuild nicht verfügbar – einfache DMG"
  STAGE="$BUILD_DIR/stage"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "Horizon Notch" -srcfolder "$STAGE" -fs HFS+ -format UDZO \
    -imagekey zlib-level=9 -ov "$DMG" > /dev/null
fi
if [ -n "${NOTARY_PROFILE:-}" ]; then
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
fi
echo "✓ DMG: $DMG"
# The built app is inside the DMG now; drop the loose copies.
./scripts/forget-builds.sh

if [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "→ Notarisiere (dauert ein paar Minuten) …"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  echo "✓ Notarisiert"
fi
