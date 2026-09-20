#!/bin/zsh
set -euo pipefail

APP_PATH="${1:?Usage: embed-widget.sh App.app [Debug|Release] [arm64|x86_64]}"
CONFIGURATION="${2:-Debug}"
ARCH="${3:-$(uname -m)}"
PROJECT_ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
MODE="${NOTCHAPP_WIDGET_MODE:-auto}"
SIGNING_IDENTITY="${NOTCHAPP_SIGNING_IDENTITY:-Apple Development: Nail Ultyev (8SY5RA8Q5F)}"
EXTENSION_PATH="$APP_PATH/Contents/PlugIns/NoolQuotaWidget.appex"

case "$MODE" in auto|enabled|disabled) ;; *) print -u2 'error: NOTCHAPP_WIDGET_MODE must be auto, enabled, or disabled'; exit 2 ;; esac
case "$CONFIGURATION" in Debug|Release) ;; *) print -u2 'error: invalid widget configuration'; exit 2 ;; esac
case "$ARCH" in arm64|x86_64) ;; *) print -u2 'error: unsupported widget architecture'; exit 2 ;; esac

AVAILABLE_IDENTITIES="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null || true)"
if [[ "$MODE" == disabled || "$AVAILABLE_IDENTITIES" != *"\"$SIGNING_IDENTITY\""* ]]; then
  if [[ "$MODE" == enabled ]]; then
    print -u2 'error: WidgetKit requires an available Apple team signing identity; ad-hoc is unsupported'
    exit 1
  fi
  /bin/rm -rf "$EXTENSION_PATH"
  /usr/libexec/PlistBuddy -c 'Delete :NoolWidgetAppGroup' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true
  print -- 'WidgetKit omitted: disabled or no team signing identity (ad-hoc builds have no shared group).'
  exit 0
fi

# Derive the actual developer team from the public certificate, not the identity's user ID.
TEAM_ID="$(/usr/bin/security find-certificate -c "$SIGNING_IDENTITY" -p | /usr/bin/openssl x509 -noout -subject -nameopt sep_multiline | /usr/bin/sed -n 's/^[[:space:]]*OU=//p')"
if ! print -r -- "$TEAM_ID" | /usr/bin/grep -Eq '^[A-Z0-9]{10}$'; then
  print -u2 'error: cannot determine Apple developer team for WidgetKit signing'
  exit 1
fi
GROUP_ID="$TEAM_ID.com.nailuyltyev.NotchApp.widgets"
DERIVED_DATA="$PROJECT_ROOT/DerivedData/Widgets"
/usr/bin/xcrun xcodebuild \
  -project "$PROJECT_ROOT/NoolWidgets.xcodeproj" \
  -scheme NoolQuotaWidget -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  ARCHS="$ARCH" ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
  DEVELOPMENT_TEAM="$TEAM_ID" NOOL_WIDGET_APP_GROUP="$GROUP_ID" build

BUILT_EXTENSION="$DERIVED_DATA/Build/Products/$CONFIGURATION/NoolQuotaWidget.appex"
[[ -d "$BUILT_EXTENSION" ]] || { print -u2 'error: widget extension was not built'; exit 1; }
/bin/mkdir -p "$APP_PATH/Contents/PlugIns"
/bin/rm -rf "$EXTENSION_PATH"
/bin/cp -R "$BUILT_EXTENSION" "$EXTENSION_PATH"
for KEY in CFBundleShortVersionString CFBundleVersion; do
  VALUE="$(/usr/libexec/PlistBuddy -c "Print :$KEY" "$APP_PATH/Contents/Info.plist")"
  /usr/libexec/PlistBuddy -c "Set :$KEY $VALUE" "$EXTENSION_PATH/Contents/Info.plist"
done
/usr/libexec/PlistBuddy -c 'Delete :NoolWidgetAppGroup' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :NoolWidgetAppGroup string $GROUP_ID" "$APP_PATH/Contents/Info.plist"
print -- "Embedded WidgetKit extension for team $TEAM_ID"
