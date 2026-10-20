#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
SIGNING_IDENTITY="${NOTCHAPP_SIGNING_IDENTITY:-Apple Development: Nail Ultyev (8SY5RA8Q5F)}"
TEST_ROOT="$(mktemp -d /private/tmp/nool-dock-signing.XXXXXX)"
APP_PATH="$TEST_ROOT/NooL App.app"
trap '/bin/rm -rf "$TEST_ROOT"' EXIT

/bin/mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
/bin/cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
/bin/cp /usr/bin/true "$APP_PATH/Contents/MacOS/NotchApp"
/bin/cp /usr/bin/true "$APP_PATH/Contents/Resources/nool-dock-recovery"
NOTCHAPP_SIGNING_IDENTITY="$SIGNING_IDENTITY" "$PROJECT_ROOT/scripts/sign-app.sh" "$APP_PATH"
SIGNATURE="$(/usr/bin/codesign -dvv "$APP_PATH/Contents/Resources/nool-dock-recovery" 2>&1)"
[[ "$SIGNATURE" == *"Authority=$SIGNING_IDENTITY"* ]] || { print -u2 'FAIL: recovery helper uses a different signing identity'; exit 1; }
/usr/bin/codesign --verify --deep --strict "$APP_PATH"
print -- 'PASS: independent Dock recovery helper is signed with the containing app identity'
