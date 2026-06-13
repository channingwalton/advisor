#!/bin/sh
# Assemble a self-contained, ad-hoc-signed Advisor.app from a release build.
# Bundles: the Swift executable, whisper.cpp dylibs (Frameworks/), the Node
# runtime, and the built sidecar (dist + node_modules). The whisper model is
# NOT bundled — Apple SpeechAnalyzer is the default engine; point whisper at a
# model via Preferences or ADVISOR_WHISPER_MODEL if you want it.
#
# Output: App/dist/Advisor.app  (drag to /Applications)
set -e
cd "$(dirname "$0")"            # App/
ROOT=..                         # repo root
OUT=dist
APP=$OUT/Advisor.app
W=$ROOT/vendor/whisper.cpp/build

[ -d "$W" ] || { echo "whisper.cpp not built at $W — see README setup"; exit 1; }

echo "==> swift build (release)"
swift build -c release

echo "==> build sidecar"
( cd "$ROOT/sidecar" && npm install --include=dev >/dev/null 2>&1 && npm run build >/dev/null )

echo "==> assemble $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"

cp .build/release/Advisor "$APP/Contents/MacOS/Advisor"
cp Resources/Info.plist   "$APP/Contents/Info.plist"

echo "==> compile app icon"
# AppIcon.iconset (the PNG source) -> AppIcon.icns in the bundle. Info.plist
# points at it via CFBundleIconFile/CFBundleIconName = AppIcon.
iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> bundle whisper dylibs"
# Flatten every dylib (and its version symlinks) into one Frameworks dir.
for dir in "$W/src" "$W/ggml/src" "$W/ggml/src/ggml-blas" "$W/ggml/src/ggml-metal"; do
    cp -a "$dir/"*.dylib "$APP/Contents/Frameworks/" 2>/dev/null || true
done
# Each dylib references its siblings via @rpath; @loader_path lets them resolve
# now that they share a directory. The main exe looks in ../Frameworks.
WABS=$(cd "$W" && pwd)
for lib in "$APP/Contents/Frameworks/"*.*.*.dylib; do
    install_name_tool -add_rpath @loader_path "$lib" 2>/dev/null || true
    # Strip the absolute build-tree rpaths baked in at link time.
    for r in "$WABS/ggml/src" "$WABS/ggml/src/ggml-blas" "$WABS/ggml/src/ggml-metal" "$WABS/src"; do
        install_name_tool -delete_rpath "$r" "$lib" 2>/dev/null || true
    done
done
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Advisor"
# Strip the dev rpaths so the bundle is self-contained on any Mac.
for r in "$WABS/src" "$WABS/ggml/src"; do
    install_name_tool -delete_rpath "$r" "$APP/Contents/MacOS/Advisor" 2>/dev/null || true
done

echo "==> bundle node + sidecar"
cp "$(node -e 'console.log(process.execPath)')" "$APP/Contents/Resources/node"
mkdir -p "$APP/Contents/Resources/sidecar"
cp -R "$ROOT/sidecar/dist" "$ROOT/sidecar/node_modules" "$ROOT/sidecar/package.json" \
      "$APP/Contents/Resources/sidecar/"

echo "==> ad-hoc codesign"
# Sign nested code first (deep is deprecated but fine for ad-hoc local use).
codesign --force --sign - "$APP/Contents/Resources/node"
find "$APP/Contents/Frameworks" -name "*.dylib" -type f \
    -exec codesign --force --sign - {} +
codesign --force --sign - "$APP/Contents/MacOS/Advisor"
codesign --force --sign - "$APP"

echo "==> done: $APP"
echo "   Unsigned/ad-hoc: first launch needs right-click > Open, or:"
echo "   xattr -dr com.apple.quarantine \"$APP\""
