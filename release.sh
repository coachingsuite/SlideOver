#!/bin/bash
# Builds build/SlideOver-<version>.dmg, signed and notarized, so it opens on other people's
# Macs without security warnings.
#
# One-time setup (needs a paid Apple Developer Program membership):
#   1. Xcode → Settings → Accounts → Manage Certificates → "+" → Developer ID Application
#   2. Create an app-specific password at account.apple.com (Sign-In and Security), then run:
#        xcrun notarytool store-credentials "SlideOver-notary" \
#          --apple-id YOUR-APPLE-ID --team-id YOUR-TEAM-ID --password APP-SPECIFIC-PASSWORD
#
# Then:  ./release.sh        (bump CFBundleShortVersionString / CFBundleVersion in Info.plist first)
set -euo pipefail
cd "$(dirname "$0")"

PROFILE="${NOTARY_PROFILE:-SlideOver-notary}"
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Developer ID Application" | sed -E 's/.*"(.*)"/\1/' || true)
if [ -z "$IDENTITY" ]; then
  echo "No \"Developer ID Application\" certificate found in your keychain."
  echo "See the setup steps at the top of release.sh."
  exit 1
fi

./build.sh

APP="build/SlideOver.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
DMG="build/SlideOver-$VERSION.dmg"

echo "Signing for distribution with: $IDENTITY"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

STAGE="build/dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "SlideOver" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "Signed $DMG, but it is NOT notarized: no notarytool profile named \"$PROFILE\"."
  echo "See the setup steps at the top of release.sh."
  exit 1
fi

echo "Sending to Apple for notarization (usually a few minutes)…"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature -v "$DMG" || true

echo "Ready to share: $DMG"
