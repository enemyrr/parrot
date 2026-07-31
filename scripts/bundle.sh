#!/usr/bin/env bash
#
# Build parrot.app — signed, optionally notarized, packaged as a DMG.
#
#   ./scripts/bundle.sh                 # ad-hoc signed, for local testing
#   ./scripts/bundle.sh --notarize      # Developer ID + notarize + staple
#
# Signing identity is picked automatically: a "Developer ID Application" cert
# if one exists, otherwise ad-hoc. Only a Developer ID build can be notarized,
# and only a notarized build opens on someone else's Mac without Gatekeeper
# complaining.
#
# Notarizing needs credentials stored once:
#   xcrun notarytool store-credentials parrot \
#     --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
#
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="parrot"
BUNDLE_ID="com.digimata.parrot"
NOTARY_PROFILE="${NOTARY_PROFILE:-parrot}"
DIST="dist"
APP="$DIST/$APP_NAME.app"

NOTARIZE=false
[[ "${1:-}" == "--notarize" ]] && NOTARIZE=true

# Version from the current tag, else the short SHA, so a dev build is
# identifiable rather than pretending to be a release.
VERSION="$(git describe --tags --exact-match 2>/dev/null || git rev-parse --short HEAD 2>/dev/null || echo "0.0.0")"
VERSION="${VERSION#v}"

echo "==> building $APP_NAME $VERSION"
swift build -c release --arch arm64 >/dev/null
BIN="$(swift build -c release --arch arm64 --show-bin-path)/$APP_NAME"
[[ -x "$BIN" ]] || { echo "no binary at $BIN" >&2; exit 1; }

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
swift scripts/make-icon.swift "$APP/Contents/Resources/$APP_NAME.icns" >/dev/null

# ---------------------------------------------------------------- signing
# SIGN_IDENTITY pins the cert explicitly. Worth setting once you have more than
# one Developer ID — otherwise this silently takes whichever sorts first.
IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  MATCHES="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -c "Developer ID Application" || true)"
  if [[ "${MATCHES:-0}" -gt 1 ]]; then
    echo "note: $MATCHES Developer ID certs found; using the first."
    echo "      set SIGN_IDENTITY='Developer ID Application: …' to choose."
  fi
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 \
    | sed -E 's/.*"(.*)"/\1/' || true)"
fi

if [[ -n "$IDENTITY" ]]; then
  echo "==> signing as: $IDENTITY"
  # --options runtime is the hardened runtime; notarization refuses without it.
  codesign --force --deep --timestamp --options runtime \
    --entitlements Resources/parrot.entitlements \
    --identifier "$BUNDLE_ID" \
    --sign "$IDENTITY" "$APP"
else
  echo "==> no Developer ID cert — signing ad-hoc (local use only)"
  echo "    friends will hit Gatekeeper; see the header of this script"
  codesign --force --deep \
    --entitlements Resources/parrot.entitlements \
    --identifier "$BUNDLE_ID" \
    --sign - "$APP"
  NOTARIZE=false
fi

codesign --verify --strict --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

# ------------------------------------------------------------ notarizing
if [[ "$NOTARIZE" == true ]]; then
  ZIP="$DIST/$APP_NAME-notarize.zip"
  echo "==> notarizing (this waits on Apple, usually a few minutes)"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  # Staple so the app validates offline, without a round trip to Apple.
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
fi

# --------------------------------------------------------------- packaging
#
# Built read-write first so Finder can be told where to put the icons and what
# to show behind them; that layout lands in the volume's .DS_Store. Then it's
# converted to a compressed read-only image.
DMG="$DIST/$APP_NAME-$VERSION.dmg"
RW_DMG="$DIST/.$APP_NAME-rw.dmg"
VOLUME="/Volumes/$APP_NAME"
echo "==> packaging $DMG"

STAGE="$(mktemp -d)"
cleanup() {
  [[ -d "$VOLUME" ]] && hdiutil detach "$VOLUME" -quiet -force 2>/dev/null || true
  rm -rf "$STAGE"
  rm -f "$RW_DMG"
}
trap cleanup EXIT

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"   # drag-to-install target
mkdir -p "$STAGE/.background"
swift scripts/make-dmg-background.swift "$STAGE/.background" >/dev/null
# One TIFF carrying both scales, so the background stays crisp on Retina.
tiffutil -cathidpicheck \
  "$STAGE/.background/background.png" "$STAGE/.background/background@2x.png" \
  -out "$STAGE/.background/background.tiff" >/dev/null 2>&1
rm -f "$STAGE/.background/background.png" "$STAGE/.background/background@2x.png"

# Room for the payload plus slack for the filesystem itself.
SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 24 ))
rm -f "$DMG" "$RW_DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" \
  -ov -format UDRW -size "${SIZE_MB}m" "$RW_DMG" >/dev/null
hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen -quiet

# Styling drives Finder over AppleEvents, which needs Automation permission —
# granted once on a real desktop, never available on a headless CI runner. The
# DMG is perfectly usable without it, so a failure here is a downgrade, not an
# error.
if osascript <<APPLESCRIPT >/dev/null 2>&1
tell application "Finder"
  tell disk "$APP_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    -- Background is a 660x340 content area (see make-dmg-background.swift).
    -- Finder's window bounds include the title bar, so 28pt is added to the
    -- height. Without it the content area ends up shorter than the background
    -- and the window scrolls.
    -- (No backticks in this heredoc: it is unquoted so $APP_NAME expands,
    --  which means bash would also run anything in backticks.)
    set the bounds of container window to {200, 120, 860, 488}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 12
    set background picture of opts to file ".background:background.tiff"
    set position of item "$APP_NAME.app" of container window to {175, 186}
    set position of item "Applications" of container window to {485, 186}
    close
    open
    update without registering applications
    delay 1
  end tell
end tell
APPLESCRIPT
then
  echo "    styled window layout applied"
else
  echo "    note: couldn't style the window (needs Finder automation access)"
  echo "          the DMG still works — icons just land in default positions"
fi

chmod -Rf go-w "$VOLUME" 2>/dev/null || true
sync
hdiutil detach "$VOLUME" -quiet
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null

echo
echo "✓ $APP"
echo "✓ $DMG"
if [[ "$NOTARIZE" == true ]]; then
  echo "  notarized and stapled — opens cleanly on any Mac"
else
  echo "  NOT notarized — fine locally, Gatekeeper will block it elsewhere"
fi
