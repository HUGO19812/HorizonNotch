#!/bin/bash
#
# Horizon Notch bauen und nach /Applications installieren - Doppelklick im
# Finder genuegt. Danach startet die App automatisch.
set -uo pipefail
cd "$(dirname "$0")" || exit 1

APP_NAME="HorizonNotch.app"
TARGET="/Applications/$APP_NAME"

echo ""
echo "  Horizon Notch bauen"
echo "  ───────────────────"
echo ""

command -v xcodebuild >/dev/null 2>&1 || {
  echo "  ✗ Xcode fehlt. Aus dem App Store installieren, dann erneut starten."
  exit 1
}

# Signiert wird mit dem lokalen Zertifikat "FlowTools Local Signing". Eine
# gleichbleibende Signatur sorgt dafuer, dass macOS erteilte Berechtigungen
# (Bedienungshilfen, Kalender ...) nach einem Neubau nicht vergisst.
if ! security find-identity -v -p codesigning | grep -q "FlowTools Local Signing"; then
  echo "  ! Zertifikat \"FlowTools Local Signing\" fehlt – baue ad hoc signiert."
  echo "    Berechtigungen muessen dann nach jedem Neubau neu erteilt werden."
  SIGN_ARGS=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual)
else
  SIGN_ARGS=()
fi

# Old copies from earlier builds (Debug, Release folder) would show up as
# extra "Horizon Notch" apps in Spotlight and Launchpad.
./scripts/forget-builds.sh
rm -rf build/release build/dd

# ".noindex" keeps Spotlight out of the build folder.
mkdir -p build
if ! xcodebuild -project HorizonNotch.xcodeproj -scheme HorizonNotch -configuration Release \
     -derivedDataPath build/release.noindex ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} build > build/release.log 2>&1; then
  echo "  ✗ Bau fehlgeschlagen – Details in build/release.log"
  grep -E "error:" build/release.log | head -10
  exit 1
fi
echo "  ✓ Gebaut"

pkill -x HorizonNotch 2>/dev/null
sleep 0.5
rm -rf "$TARGET"
cp -R "build/release.noindex/Build/Products/Release/$APP_NAME" "$TARGET"
# Only the installed copy should exist.
./scripts/forget-builds.sh
echo "  ✓ Installiert: $TARGET"

open "$TARGET"
echo "  ✓ Gestartet"
echo ""
