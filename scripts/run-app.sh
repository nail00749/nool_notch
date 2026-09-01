#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

if [[ -d "/Applications/Xcode-beta.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
fi

XCRUN="/usr/bin/xcrun"
"$XCRUN" swift build
BIN_PATH="$("$XCRUN" swift build --show-bin-path)"
APP_PATH="$PROJECT_ROOT/Build/NotchApp.app"

mkdir -p "$APP_PATH/Contents/MacOS"
cp "$BIN_PATH/NotchApp" "$APP_PATH/Contents/MacOS/NotchApp"
cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
"$PROJECT_ROOT/scripts/sign-app.sh" "$APP_PATH"

# Replace the running instance so the app cannot keep an older binary in memory.
/usr/bin/killall NotchApp 2>/dev/null || true
open -n "$APP_PATH"
