#!/bin/sh
# Clean-build Advisor.app and install it into ~/Applications, replacing any
# previous version. Wipes prior build artefacts first (so it's a true clean
# build), then wraps package.sh and copies the result across.
#
# Output: ~/Applications/Advisor.app
set -e
cd "$(dirname "$0")"            # App/
DEST="$HOME/Applications"
APP=dist/Advisor.app
INSTALLED="$DEST/Advisor.app"

echo "==> clean"
swift package clean
rm -rf dist

echo "==> package"
sh package.sh

# Re-sign with a STABLE identity if one exists, so macOS TCC grants (Microphone,
# Screen & System Audio Recording) survive rebuilds. package.sh ad-hoc-signs,
# whose code hash rotates every build — that makes macOS treat each rebuild as a
# new app and silently drop the grants. A fixed identity keeps the Designated
# Requirement constant. Prefer a Developer ID cert; else a self-signed "Advisor
# Dev" identity (create one in Keychain Access ▸ Certificate Assistant ▸ Create a
# Certificate: name "Advisor Dev", type Code Signing). If neither is present,
# keep the ad-hoc signature (CI / fresh machines still work).
SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | awk -F'"' '/Developer ID Application/{print $2; exit}')}"
if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY=$(security find-identity -p codesigning \
    | awk -F'"' '/Advisor Dev/{print $2; exit}')
fi
if [ -n "$SIGN_IDENTITY" ]; then
  echo "==> re-sign with stable identity: $SIGN_IDENTITY"
  codesign --force --sign "$SIGN_IDENTITY" "$APP/Contents/Resources/node"
  codesign --force --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/Advisor"
  codesign --force --sign "$SIGN_IDENTITY" "$APP"
else
  echo "==> no stable identity found; keeping ad-hoc signature (TCC grants will"
  echo "    reset on each rebuild — see install.sh comment to set one up)"
fi

echo "==> quit running Advisor (if any)"
osascript -e 'tell application "Advisor" to quit' >/dev/null 2>&1 || true

echo "==> install to $INSTALLED"
mkdir -p "$DEST"
rm -rf "$INSTALLED"
ditto "$APP" "$INSTALLED"

echo "==> clear quarantine"
xattr -dr com.apple.quarantine "$INSTALLED" 2>/dev/null || true

echo "==> done: $INSTALLED"
