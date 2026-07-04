#!/bin/sh
# Build and Developer-ID-sign Advisor.app (hardened runtime, inside-out).
# Notarisation happens once, in dmg.sh: submitting the DMG makes Apple scan the
# nested .app too, so a separate app-level round (the old notarize.sh zip
# upload) is redundant. Trade-off: the app inside the DMG carries no stapled
# ticket, so Gatekeeper fetches it online on first launch — fine for website
# distribution. The Mac App Store is impractical here: it requires the App
# Sandbox, which fights the bundled Node sidecar + $HOME reads.
#
# Prerequisites (one-off):
#   - Apple Developer Program membership.
#   - A "Developer ID Application" certificate in your login keychain.
#
# Config (env overrides):
#   SIGN_IDENTITY   signing identity; defaults to the first "Developer ID
#                   Application" found in the keychain.
#
# Output: App/dist/Advisor.app (signed, not notarised).
# Safe to run before you have a cert: it exits early with a clear message.
set -e
cd "$(dirname "$0")"            # App/

APP=dist/Advisor.app
ENT=Resources/entitlements.plist

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

# Assemble the bundle from a release build; we re-sign it below.
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

echo "==> sign bundled Mach-O executables"
# Entitlements on every nested executable, not just node: the agent SDK vendors
# a Bun-compiled `claude` binary, and JavaScriptCore under the hardened runtime
# without allow-jit loses SharedArrayBuffer — the CLI then exits 1 at startup
# (broke the v0.2.0 DMG).
find "$APP/Contents" -type f -perm -111 -print | while IFS= read -r candidate; do
  if file "$candidate" | grep -q 'Mach-O'; then
    sign --entitlements "$ENT" "$candidate"
  fi
done

echo "==> sign bundled node, main executable, then the bundle"
sign --entitlements "$ENT" "$APP/Contents/Resources/node"
sign --entitlements "$ENT" "$APP/Contents/MacOS/Advisor"
sign --entitlements "$ENT" "$APP"

echo "==> verify signature"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> done: $APP (signed; dmg.sh notarises the DMG)"
