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
# Dev deps (typescript) are needed to compile. Capture output to a log and print
# it on failure, so a broken install/build is diagnosable rather than swallowed
# by set -e with no message (issue #64).
SIDECAR_LOG=$(mktemp)
if ! ( cd "$ROOT/sidecar" && npm install --include=dev && npm run build ) >"$SIDECAR_LOG" 2>&1; then
  echo "sidecar build failed:"; cat "$SIDECAR_LOG"; rm -f "$SIDECAR_LOG"; exit 1
fi
rm -f "$SIDECAR_LOG"

echo "==> assemble $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/Advisor "$APP/Contents/MacOS/Advisor"
cp Resources/Info.plist   "$APP/Contents/Info.plist"

# Stamp the version: marketing version from the repo-root VERSION file, build
# number from the commit count (monotonic, no bookkeeping).
VERSION=$(tr -d '[:space:]' < "$ROOT/VERSION")
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
echo "==> stamp version $VERSION ($BUILD)"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD" "$APP/Contents/Info.plist"

echo "==> compile app icon"
# AppIcon.iconset (the PNG source) -> AppIcon.icns in the bundle. Info.plist
# points at it via CFBundleIconFile/CFBundleIconName = AppIcon.
iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

# Terms of use, shown by the first-run acceptance sheet (TermsAcceptance).
cp "$ROOT/TERMS.md" "$APP/Contents/Resources/TERMS.md"

echo "==> bundle node + sidecar"
cp "$(node -e 'console.log(process.execPath)')" "$APP/Contents/Resources/node"
mkdir -p "$APP/Contents/Resources/sidecar"
cp -R "$ROOT/sidecar/dist" "$ROOT/sidecar/node_modules" "$ROOT/sidecar/package.json" \
      "$APP/Contents/Resources/sidecar/"
# Drop dev dependencies (typescript, @types) from the shipped copy — the dev
# checkout's node_modules is left intact for the next build (issue #64). Bloat
# only, so a prune failure warns rather than aborting the package.
PRUNE_LOG=$(mktemp)
if ! ( cd "$APP/Contents/Resources/sidecar" && npm prune --omit=dev ) >"$PRUNE_LOG" 2>&1; then
  echo "warning: could not prune dev deps from bundled sidecar (shipping full node_modules):"
  cat "$PRUNE_LOG"
fi
rm -f "$PRUNE_LOG"

sh sign-local.sh "$APP"

echo "==> done: $APP"
echo "   First launch may need right-click > Open, or:"
echo "   xattr -dr com.apple.quarantine \"$APP\""
