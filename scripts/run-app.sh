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
APP_PATH="$PROJECT_ROOT/Build/NooL App.app"
LEGACY_APP_PATH="$PROJECT_ROOT/Build/NotchApp.app"
EXPECTED_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PROJECT_ROOT/Resources/Info.plist")"

if [[ -L "$PROJECT_ROOT/Build" ]]; then
  print -u2 -- "error: Build directory is a symlink; refusing to modify an external location"
  exit 1
fi

validate_generated_bundle() {
  local bundle_path="$1"
  local bundle_id=""
  if [[ -L "$bundle_path" || ! -d "$bundle_path" || ! -x "$bundle_path/Contents/MacOS/NotchApp" ]]; then
    print -u2 -- "error: refusing to replace unexpected bundle at $bundle_path"
    exit 1
  fi
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle_path/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$bundle_id" != "$EXPECTED_BUNDLE_ID" ]]; then
    print -u2 -- "error: bundle identifier mismatch at $bundle_path; leaving it untouched"
    exit 1
  fi
}

if [[ -e "$APP_PATH" || -L "$APP_PATH" ]]; then
  validate_generated_bundle "$APP_PATH"
fi
if [[ -e "$LEGACY_APP_PATH" || -L "$LEGACY_APP_PATH" ]]; then
  validate_generated_bundle "$LEGACY_APP_PATH"
  if [[ -e "$APP_PATH" || -L "$APP_PATH" ]]; then
    print -u2 -- "error: both old and new app bundles exist; resolve the ambiguity before rebuilding"
    exit 1
  fi
  /bin/mv "$LEGACY_APP_PATH" "$APP_PATH"
fi

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
"$PROJECT_ROOT/scripts/embed-widget.sh" "$APP_PATH"
"$PROJECT_ROOT/scripts/sign-app.sh" "$APP_PATH"

# Replace the running instance so the app cannot keep an older binary in memory.
/usr/bin/killall NotchApp 2>/dev/null || true
open -n "$APP_PATH"
