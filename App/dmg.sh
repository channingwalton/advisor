#!/bin/sh
# Build Advisor.app and wrap it in a compressed DMG for sharing.
#
# Output: App/dist/Advisor.dmg
set -e
cd "$(dirname "$0")"            # App/

APP=dist/Advisor.app
DMG=dist/Advisor.dmg
RW_DMG=dist/Advisor-rw.dmg
MOUNT=dist/dmg-mount
VOLNAME=Advisor

cleanup() {
  hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true
  rm -f "$RW_DMG"
  rmdir "$MOUNT" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

echo "==> package"
sh package.sh

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

echo "==> done: $DMG"
echo "   Ad-hoc signed: first launch may need right-click > Open, or:"
echo "   xattr -dr com.apple.quarantine /Applications/Advisor.app"
