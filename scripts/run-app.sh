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

mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_PATH/NotchApp" "$APP_PATH/Contents/MacOS/NotchApp"
cp "$BIN_PATH/NoolAgentBridge" "$APP_PATH/Contents/Resources/nool-agent-bridge"
chmod 755 "$APP_PATH/Contents/Resources/nool-agent-bridge"
cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
cp "$PROJECT_ROOT/Resources/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
RESOURCE_BUNDLES=("$BIN_PATH"/*.bundle(N))
for RESOURCE_BUNDLE in "${RESOURCE_BUNDLES[@]}"; do
  BUNDLE_NAME="${RESOURCE_BUNDLE:t}"
  /bin/rm -rf "$APP_PATH/Contents/Resources/$BUNDLE_NAME"
  /bin/cp -R "$RESOURCE_BUNDLE" "$APP_PATH/Contents/Resources/$BUNDLE_NAME"
done
"$PROJECT_ROOT/scripts/sign-app.sh" "$APP_PATH"

# Replace the running instance so the app cannot keep an older binary in memory.
/usr/bin/killall NotchApp 2>/dev/null || true
open -n "$APP_PATH"
