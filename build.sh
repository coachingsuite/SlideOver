#!/bin/bash
# Builds SlideOver.app into ./build and (with --run) launches it.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/SlideOver.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/SlideOver "$APP/Contents/MacOS/SlideOver"
cp Info.plist "$APP/Contents/Info.plist"

# App icon from Icon/AppIcon-light.png / AppIcon-dark.png. A plain .icns can hold only one
# look, so the variant matching the system appearance at build time is used.
# Force one with:  ICON=light ./build.sh   or   ICON=dark ./build.sh
# Preferred: the adaptive icon (Icon/AppIcon.icon, Apple's Icon Composer format). macOS then
# switches it by itself between light, dark, clear and tinted. Needs Xcode 26 or newer.
# Setting ICON=light or ICON=dark skips it and forces the plain icon.
ICON_DONE=0
if [ -d "Icon/AppIcon.icon" ] && [ -z "${ICON:-}" ]; then
  OUT="build/icon-out"
  rm -rf "$OUT"
  mkdir -p "$OUT" "$APP/Contents/Resources"
  if xcrun actool "Icon/AppIcon.icon" --compile "$OUT" \
       --output-format human-readable-text --notices --warnings --errors \
       --output-partial-info-plist "$OUT/partial.plist" \
       --app-icon AppIcon --include-all-app-icons \
       --enable-on-demand-resources NO --development-region en \
       --target-device mac --minimum-deployment-target 14.0 --platform macosx \
       > "$OUT/actool.log" 2>&1 && [ -f "$OUT/Assets.car" ]; then
    cp "$OUT/Assets.car" "$APP/Contents/Resources/"
    if [ -f "$OUT/AppIcon.icns" ]; then cp "$OUT/AppIcon.icns" "$APP/Contents/Resources/"; fi
    ICON_DONE=1
    echo "Icon: adaptive (light / dark / clear / tinted)"
  else
    echo "Adaptive icon failed, falling back to the plain icon. actool output:"
    cat "$OUT/actool.log" || true
  fi
fi
VARIANT=light
if [ "$(defaults read -g AppleInterfaceStyle 2>/dev/null)" = "Dark" ]; then VARIANT=dark; fi
VARIANT="${ICON:-$VARIANT}"
if [ "$ICON_DONE" = 0 ] && [ -f "Icon/AppIcon-$VARIANT.png" ]; then
  SET="build/AppIcon.iconset"
  rm -rf "$SET"
  mkdir -p "$SET" "$APP/Contents/Resources"
  for s in 16 32 128 256 512; do
    sips -z $s $s "Icon/AppIcon-$VARIANT.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "Icon/AppIcon-$VARIANT.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$SET" -o "$APP/Contents/Resources/AppIcon.icns"
  echo "Icon: $VARIANT"
fi

# Prefer a real "Apple Development" certificate: then macOS keeps the
# Accessibility / Screen Recording permissions across rebuilds.
# With ad-hoc signing ("-") you have to re-grant them after each build.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Apple Development" | sed -E 's/.*"(.*)"/\1/' || true)
if [ -n "$IDENTITY" ]; then
  echo "Signing with: $IDENTITY"
  codesign --force --sign "$IDENTITY" "$APP"
else
  echo "No Apple Development certificate found, signing ad-hoc"
  codesign --force --sign - "$APP"
fi

touch "$APP"   # nudges Finder to refresh the icon
echo "Built $APP"

if [ "${1:-}" = "--run" ]; then
  pkill -x SlideOver 2>/dev/null || true
  # give the old instance time to put its windows back before starting the new one
  for _ in $(seq 1 50); do pgrep -x SlideOver >/dev/null || break; sleep 0.1; done
  open "$APP"
fi
