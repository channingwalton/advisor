#!/bin/sh
# Sign Advisor.app for local use. Prefer a stable signing identity so macOS TCC
# grants survive rebuilds; fall back to ad-hoc signing when no identity exists.
set -e

APP=${1:?usage: sh sign-local.sh path/to/Advisor.app}

if [ ! -d "$APP" ]; then
  echo "sign-local.sh: app not found: $APP" >&2
  exit 1
fi

SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | awk -F'"' '/Developer ID Application/{print $2; exit}')}"
if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning \
    | awk -F'"' '/Advisor Dev/{print $2; exit}')
fi

if [ -n "$SIGN_IDENTITY" ]; then
  echo "==> codesign with stable identity: $SIGN_IDENTITY"
  codesign --force --sign "$SIGN_IDENTITY" "$APP/Contents/Resources/node"
  codesign --force --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/Advisor"
  codesign --force --sign "$SIGN_IDENTITY" "$APP"
else
  echo "==> ad-hoc codesign"
  codesign --force --sign - "$APP/Contents/Resources/node"
  codesign --force --sign - "$APP/Contents/MacOS/Advisor"
  codesign --force --sign - "$APP"
  echo "==> no stable identity found; TCC grants will reset on rebuild"
fi
