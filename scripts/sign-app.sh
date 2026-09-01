#!/bin/zsh
set -euo pipefail

APP_PATH="${1:?Usage: sign-app.sh /path/to/App.app}"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")"
DESIGNATED_REQUIREMENT="=designated => identifier \"$BUNDLE_ID\""
SIGNING_IDENTITY="${NOTCHAPP_SIGNING_IDENTITY:-Apple Development: Nail Ultyev (8SY5RA8Q5F)}"
ALLOW_ADHOC="${NOTCHAPP_ALLOW_ADHOC:-0}"

AVAILABLE_IDENTITIES="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null || true)"

record_signing_mode() {
  local mode="$1"
  if /usr/libexec/PlistBuddy -c 'Print :NotchAppSigningMode' "$APP_PATH/Contents/Info.plist" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :NotchAppSigningMode $mode" "$APP_PATH/Contents/Info.plist"
  else
    /usr/libexec/PlistBuddy -c "Add :NotchAppSigningMode string $mode" "$APP_PATH/Contents/Info.plist"
  fi
}

if [[ "$AVAILABLE_IDENTITIES" == *"\"$SIGNING_IDENTITY\""* ]]; then
  record_signing_mode stable
  /usr/bin/codesign \
    --force \
    --deep \
    --timestamp=none \
    --sign "$SIGNING_IDENTITY" \
    "$APP_PATH"
else
  if [[ "$ALLOW_ADHOC" != "1" ]]; then
    print -u2 -- "error: signing identity '$SIGNING_IDENTITY' is unavailable"
    print -u2 -- "error: refusing ad-hoc signing because it can reset Accessibility permission"
    print -u2 -- "error: set NOTCHAPP_ALLOW_ADHOC=1 only for an intentional temporary build"
    exit 1
  fi
  print -u2 -- "warning: signing identity '$SIGNING_IDENTITY' is unavailable; explicit ad-hoc signing enabled"
  record_signing_mode ad-hoc
  /usr/bin/codesign \
    --force \
    --deep \
    --sign - \
    --requirements "$DESIGNATED_REQUIREMENT" \
    "$APP_PATH"
fi
