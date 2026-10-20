#!/bin/sh
# Run a command under the Xcode pinned in the repo's .xcode-version, so the
# app builds with the same toolchain here and in CI whatever xcode-select
# points at. The pinned Xcode is found by version among /Applications/Xcode*.app
# (XCODE_APPS_DIR overrides that folder, for tests); without it the command
# doesn't run.
#
# Usage: sh xcode.sh swift build ...
set -eu
if [ "$#" -eq 0 ]; then
    echo "usage: sh xcode.sh <command> [args...]" >&2
    exit 2
fi
pin=$(tr -d '[:space:]' < "$(dirname "$0")/../.xcode-version")
apps=${XCODE_APPS_DIR:-/Applications}
found=""
for app in "$apps"/Xcode*.app; do
    plist="$app/Contents/Info.plist"
    [ -f "$plist" ] || continue
    version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null) || continue
    if [ "$version" = "$pin" ]; then
        DEVELOPER_DIR="$app/Contents/Developer"
        export DEVELOPER_DIR
        exec "$@"
    fi
    found="$found $version"
done
echo "error: Xcode $pin, pinned in .xcode-version, is not in $apps (found:${found:- none})." >&2
echo "Install it from https://developer.apple.com/download/all/ as $apps/Xcode-$pin.app." >&2
exit 1
