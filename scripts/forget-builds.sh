#!/bin/bash
#
# Removes Horizon Notch build products inside build/ and tells macOS to
# forget them, so Spotlight, Launchpad and "Open With" only know the copy in
# /Applications. Called by build.command and make-dmg.sh.
cd "$(dirname "$0")/.." || exit 0
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# Xcode's own builds stay (Xcode needs them) but are forgotten too.
for app in "$HOME"/Library/Developer/Xcode/DerivedData/HorizonNotch-*/Build/Products/*/HorizonNotch.app; do
  [ -d "$app" ] && [ -x "$LSREGISTER" ] && "$LSREGISTER" -u "$app" 2>/dev/null
done
[ -d build ] || exit 0
find build -name "HorizonNotch.app" -type d -prune 2>/dev/null | while read -r app; do
  [ -x "$LSREGISTER" ] && "$LSREGISTER" -u "$app" 2>/dev/null
  rm -rf "$app"
done
