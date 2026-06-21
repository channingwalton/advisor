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

echo "==> quit running Advisor (if any)"
osascript -e 'tell application "Advisor" to quit' >/dev/null 2>&1 || true

echo "==> install to $INSTALLED"
mkdir -p "$DEST"
rm -rf "$INSTALLED"
ditto "$APP" "$INSTALLED"

echo "==> clear quarantine"
xattr -dr com.apple.quarantine "$INSTALLED" 2>/dev/null || true

echo "==> done: $INSTALLED"
