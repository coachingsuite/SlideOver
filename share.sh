#!/bin/bash
# Builds SlideOver and packs it into build/SlideOver.dmg to share with friends.
# Not notarized: each friend has to allow it once (see "How to open.txt" inside the DMG).
# For a notarized DMG that opens without that step, use release.sh instead.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

STAGE="build/dmg"
DMG="build/SlideOver.dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R build/SlideOver.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/How to open.txt" <<'TXT'
SlideOver - iPad-style Slide Over for any Mac window
Needs macOS 14 or newer.

1. Drag SlideOver onto the Applications folder next to it.
2. Open SlideOver from Applications. macOS will say it can't be verified. Click Done.
3. Open System Settings > Privacy & Security, scroll down, and click "Open Anyway"
   next to the SlideOver message. Confirm.
4. SlideOver's setup window opens. Allow Accessibility (required) and Screen Recording
   (recommended), then click "Relaunch SlideOver".

SlideOver lives in the menu bar (no Dock icon). The shortcuts are listed in the setup
window and can be changed under "Keyboard Shortcuts..." in its menu.
TXT

hdiutil create -volname "SlideOver" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "Ready to share: $(pwd)/$DMG"
open -R "$DMG"
