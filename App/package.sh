#!/bin/sh
# Assemble a self-contained Advisor.app from a release build.
# Uses a stable local signing identity when available; otherwise ad-hoc signs.
# Bundles: the Swift executable, the Node runtime, and the built sidecar
# (dist + node_modules). Transcription is Apple's on-device SpeechAnalyzer,
# so there are no model files or extra dylibs to ship.
#
# Output: App/dist/Advisor.app  (drag to /Applications)
set -e
cd "$(dirname "$0")"            # App/
ROOT=..                         # repo root
OUT=dist
APP=$OUT/Advisor.app

echo "==> swift build (release)"
swift build -c release

echo "==> build sidecar"
( cd "$ROOT/sidecar" && npm install --include=dev >/dev/null 2>&1 && npm run build >/dev/null )

echo "==> assemble $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/Advisor "$APP/Contents/MacOS/Advisor"
cp Resources/Info.plist   "$APP/Contents/Info.plist"

echo "==> compile app icon"
# AppIcon.iconset (the PNG source) -> AppIcon.icns in the bundle. Info.plist
# points at it via CFBundleIconFile/CFBundleIconName = AppIcon.
iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> bundle node + sidecar"
cp "$(node -e 'console.log(process.execPath)')" "$APP/Contents/Resources/node"
mkdir -p "$APP/Contents/Resources/sidecar"
cp -R "$ROOT/sidecar/dist" "$ROOT/sidecar/node_modules" "$ROOT/sidecar/package.json" \
      "$APP/Contents/Resources/sidecar/"

sh sign-local.sh "$APP"

echo "==> done: $APP"
echo "   First launch may need right-click > Open, or:"
echo "   xattr -dr com.apple.quarantine \"$APP\""
