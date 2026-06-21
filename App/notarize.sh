#!/bin/sh
# Build, Developer-ID-sign, notarize and staple Advisor.app for distribution
# OUTSIDE the Mac App Store. The Mac App Store is impractical here: it requires
# the App Sandbox, which fights the bundled Node sidecar + $HOME reads.
#
# Prerequisites (one-off):
#   - Apple Developer Program membership.
#   - A "Developer ID Application" certificate in your login keychain.
#   - Stored notarytool credentials, e.g.:
#       xcrun notarytool store-credentials "advisor-notary" \
#         --apple-id you@example.com --team-id TEAMID --password <app-specific-pw>
#
# Config (env overrides):
#   SIGN_IDENTITY   signing identity; defaults to the first "Developer ID
#                   Application" found in the keychain.
#   NOTARY_PROFILE  notarytool keychain profile name (default: advisor-notary).
#
# Output: App/dist/Advisor.app (signed + stapled) and App/dist/Advisor.zip.
# Safe to run before you have a cert: it exits early with a clear message.
set -e
cd "$(dirname "$0")"            # App/

APP=dist/Advisor.app
ENT=Resources/entitlements.plist
ZIP=dist/Advisor.zip
NOTARY_PROFILE="${NOTARY_PROFILE:-advisor-notary}"

# Resolve the signing identity (explicit override, else first Developer ID in keychain).
SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | awk -F'"' '/Developer ID Application/{print $2; exit}')}"
if [ -z "$SIGN_IDENTITY" ]; then
  echo "error: no 'Developer ID Application' identity found." >&2
  echo "       Install one (Xcode > Settings > Accounts > Manage Certificates)" >&2
  echo "       or set SIGN_IDENTITY=… explicitly." >&2
  exit 1
fi
echo "==> identity: $SIGN_IDENTITY"

# Assemble the (ad-hoc) bundle from a release build; we re-sign it below.
echo "==> package (release build + assemble)"
sh package.sh >/dev/null

# Developer-ID re-sign, hardened runtime + secure timestamp, INSIDE-OUT
# (nested Mach-Os first, the bundle last) or codesign rejects the outer seal.
sign() { codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$@"; }

echo "==> sign native addons (node_modules *.node / *.dylib)"
find "$APP/Contents/Resources/sidecar/node_modules" \
  \( -name '*.node' -o -name '*.dylib' \) -print0 \
  | xargs -0 -I{} codesign --force --options runtime --timestamp \
      --sign "$SIGN_IDENTITY" {}

echo "==> sign bundled node, main executable, then the bundle"
sign --entitlements "$ENT" "$APP/Contents/Resources/node"
sign --entitlements "$ENT" "$APP/Contents/MacOS/Advisor"
sign --entitlements "$ENT" "$APP"

echo "==> verify signature"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> notarize (this can take a few minutes)"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
# --wait blocks until Apple finishes; on rejection it exits non-zero (set -e
# stops here). Inspect a failed run with: xcrun notarytool log <id> --keychain-profile "$NOTARY_PROFILE"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> staple ticket (so it verifies offline)"
xcrun stapler staple "$APP"

echo "==> Gatekeeper assessment"
spctl -a -vvv -t install "$APP"

# Re-zip the stapled app for distribution (the pre-notarization zip lacks the ticket).
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> done: $APP (stapled) and $ZIP (distributable)"
