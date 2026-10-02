#!/bin/sh
# Build and Developer-ID-sign Advisor.app (sign.sh), wrap it in a compressed
# DMG, then sign, notarise and staple the DMG. One notary round: Apple scans
# the nested .app as part of the DMG submission (see sign.sh).
#
# Prerequisite beyond sign.sh's: stored notarytool credentials, e.g.
#   xcrun notarytool store-credentials "advisor-notary" \
#     --apple-id you@example.com --team-id TEAMID --password <app-specific-pw>
# NOTARY_PROFILE overrides the profile name (default: advisor-notary).
#
# Output: App/dist/Advisor-<version>.dmg (version from the repo-root VERSION file)
set -e
cd "$(dirname "$0")"            # App/

APP=dist/Advisor.app
VERSION=$(tr -d '[:space:]' < ../VERSION)
DMG=dist/Advisor-$VERSION.dmg
STAGE=dist/dmg-stage
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
  rm -rf "$STAGE"
  if [ -n "$SUBMISSION_PLIST" ]; then
    rm -f "$SUBMISSION_PLIST"
  fi
}
trap cleanup EXIT HUP INT TERM

echo "==> build and sign app"
SIGN_IDENTITY="$SIGN_IDENTITY" sh sign.sh

echo "==> stage image contents"
rm -f "$DMG"
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Advisor.app"
ln -s /Applications "$STAGE/Applications"

# APFS volume, LZFSE-compressed (ULFO). Replaces the deprecated
# `hdiutil create -size` + `hdiutil convert -format` pair.
echo "==> create $DMG"
diskutil image create from --format ULFO --volumeName "$VOLNAME" "$STAGE" "$DMG" >/dev/null

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
