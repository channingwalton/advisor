#!/bin/sh
# Build, Developer-ID-sign, notarise and staple Advisor.app, then wrap it in a
# signed, notarised and stapled compressed DMG for distribution.
#
# Output: App/dist/Advisor.dmg
set -e
cd "$(dirname "$0")"            # App/

APP=dist/Advisor.app
DMG=dist/Advisor.dmg
RW_DMG=dist/Advisor-rw.dmg
MOUNT=dist/dmg-mount
VOLNAME=Advisor
NOTARY_PROFILE="${NOTARY_PROFILE:-advisor-notary}"

SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | awk -F'"' '/Developer ID Application/{print $2; exit}')}"
if [ -z "$SIGN_IDENTITY" ]; then
  echo "error: no 'Developer ID Application' identity found." >&2
  echo "       Install one (Xcode > Settings > Accounts > Manage Certificates)" >&2
  echo "       or set SIGN_IDENTITY=... explicitly." >&2
  exit 1
fi
echo "==> identity: $SIGN_IDENTITY"

SUBMISSION_PLIST=

cleanup() {
  hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true
  rm -f "$RW_DMG"
  if [ -n "$SUBMISSION_PLIST" ]; then
    rm -f "$SUBMISSION_PLIST"
  fi
  rmdir "$MOUNT" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

echo "==> build, sign, notarise and staple app"
SIGN_IDENTITY="$SIGN_IDENTITY" NOTARY_PROFILE="$NOTARY_PROFILE" sh notarize.sh

echo "==> create writable image"
rm -f "$DMG" "$RW_DMG"
mkdir -p "$MOUNT"
SIZE_KB=$(du -sk "$APP" | awk '{ print int(($1 * 12 / 10) + 262144) }')
hdiutil create -size "${SIZE_KB}k" -fs HFS+ -volname "$VOLNAME" "$RW_DMG" >/dev/null

echo "==> copy app into image"
hdiutil attach "$RW_DMG" -mountpoint "$MOUNT" -nobrowse -quiet
ditto "$APP" "$MOUNT/Advisor.app"
ln -s /Applications "$MOUNT/Applications"
hdiutil detach "$MOUNT" -quiet

echo "==> create $DMG"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null

echo "==> sign $DMG"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"

echo "==> verify DMG signature"
codesign --verify --verbose=2 "$DMG"

echo "==> notarise DMG (this can take a few minutes)"
SUBMISSION_PLIST=$(mktemp "${TMPDIR:-/tmp}/advisor-dmg-notary.XXXXXX")
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait \
  --output-format plist >"$SUBMISSION_PLIST"
STATUS=$(plutil -extract status raw -o - "$SUBMISSION_PLIST")
SUBMISSION_ID=$(plutil -extract id raw -o - "$SUBMISSION_PLIST")
if [ "$STATUS" != "Accepted" ]; then
  echo "error: notarization $SUBMISSION_ID finished with status: $STATUS" >&2
  xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
  exit 1
fi

echo "==> staple DMG ticket"
xcrun stapler staple "$DMG"

echo "==> validate stapled DMG"
xcrun stapler validate "$DMG"

echo "==> Gatekeeper assessment"
spctl -a -vvv -t open --context context:primary-signature "$DMG"

echo "==> done: $DMG (Developer ID signed, notarised and stapled)"
