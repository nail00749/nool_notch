#!/bin/zsh
set -euo pipefail

APP_PATH="${1:?Usage: sign-app.sh /path/to/App.app}"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")"
DESIGNATED_REQUIREMENT="=designated => identifier \"$BUNDLE_ID\""
SIGNING_IDENTITY="${NOTCHAPP_SIGNING_IDENTITY:-Apple Development: Nail Ultyev (8SY5RA8Q5F)}"
ALLOW_ADHOC="${NOTCHAPP_ALLOW_ADHOC:-0}"

AVAILABLE_IDENTITIES="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null || true)"
WIDGET_PATH="$APP_PATH/Contents/PlugIns/NoolQuotaWidget.appex"
WIDGET_GROUP="$(/usr/libexec/PlistBuddy -c 'Print :NoolWidgetAppGroup' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
COOLING_HELPER_PATH="$APP_PATH/Contents/MacOS/NoolCoolingHelper"
COOLING_HELPER_PLIST="$APP_PATH/Contents/Library/LaunchDaemons/com.nool.cooling-helper.plist"
COOLING_HELPER_ID="com.nool.cooling-helper"
ENTITLEMENTS_DIR=""
trap '[[ -z "$ENTITLEMENTS_DIR" ]] || /bin/rm -rf "$ENTITLEMENTS_DIR"' EXIT

if [[ -d "$WIDGET_PATH" && -z "$WIDGET_GROUP" ]] || [[ ! -d "$WIDGET_PATH" && -n "$WIDGET_GROUP" ]]; then
  print -u2 'error: widget bundle and shared app group must be configured together'
  exit 1
fi

if [[ -e "$COOLING_HELPER_PATH" || -e "$COOLING_HELPER_PLIST" ]]; then
  if [[ ! -x "$COOLING_HELPER_PATH" || ! -f "$COOLING_HELPER_PLIST" ]]; then
    print -u2 'error: cooling helper executable and LaunchDaemon plist must be embedded together'
    exit 1
  fi
  HELPER_LABEL="$(/usr/libexec/PlistBuddy -c 'Print :Label' "$COOLING_HELPER_PLIST")"
  HELPER_PROGRAM="$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "$COOLING_HELPER_PLIST")"
  HELPER_MACH_SERVICE="$(/usr/libexec/PlistBuddy -c 'Print :MachServices:com.nool.cooling-helper' "$COOLING_HELPER_PLIST")"
  if [[ "$HELPER_LABEL" != "$COOLING_HELPER_ID" \
      || "$HELPER_PROGRAM" != 'Contents/MacOS/NoolCoolingHelper' \
      || "$HELPER_MACH_SERVICE" != true ]]; then
    print -u2 'error: cooling helper LaunchDaemon identifiers or BundleProgram do not match'
    exit 1
  fi
fi

record_signing_mode() {
  local mode="$1"
  if /usr/libexec/PlistBuddy -c 'Print :NotchAppSigningMode' "$APP_PATH/Contents/Info.plist" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :NotchAppSigningMode $mode" "$APP_PATH/Contents/Info.plist"
  else
    /usr/libexec/PlistBuddy -c "Add :NotchAppSigningMode string $mode" "$APP_PATH/Contents/Info.plist"
  fi
}

if [[ "$AVAILABLE_IDENTITIES" == *"\"$SIGNING_IDENTITY\""* ]]; then
  APP_SIGNING_OPTIONS=()
  if [[ -d "$WIDGET_PATH" ]]; then
    TEAM_ID="$(/usr/bin/security find-certificate -c "$SIGNING_IDENTITY" -p | /usr/bin/openssl x509 -noout -subject -nameopt sep_multiline | /usr/bin/sed -n 's/^[[:space:]]*OU=//p')"
    EXTENSION_GROUP="$(/usr/libexec/PlistBuddy -c 'Print :NoolWidgetAppGroup' "$WIDGET_PATH/Contents/Info.plist")"
    if [[ -z "$TEAM_ID" || "$WIDGET_GROUP" != "$TEAM_ID.com.nailuyltyev.NotchApp.widgets" || "$EXTENSION_GROUP" != "$WIDGET_GROUP" ]]; then
      print -u2 'error: widget app group does not match the signing team or containing app'
      exit 1
    fi
    ENTITLEMENTS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nool-widget-signing.XXXXXX")"
    for NAME in app widget; do
      FILE="$ENTITLEMENTS_DIR/$NAME.plist"
      /usr/bin/plutil -create xml1 "$FILE"
      /usr/libexec/PlistBuddy -c 'Add :com.apple.security.application-groups array' "$FILE"
      /usr/libexec/PlistBuddy -c "Add :com.apple.security.application-groups:0 string $WIDGET_GROUP" "$FILE"
    done
    /usr/libexec/PlistBuddy -c 'Add :com.apple.security.app-sandbox bool true' "$ENTITLEMENTS_DIR/widget.plist"
    /usr/bin/codesign --force --timestamp=none --sign "$SIGNING_IDENTITY" \
      --entitlements "$ENTITLEMENTS_DIR/widget.plist" "$WIDGET_PATH"
    APP_SIGNING_OPTIONS=(--entitlements "$ENTITLEMENTS_DIR/app.plist")
  fi
  if [[ -f "$APP_PATH/Contents/Resources/nool-agent-bridge" ]]; then
    /usr/bin/codesign --force --timestamp=none --sign "$SIGNING_IDENTITY" "$APP_PATH/Contents/Resources/nool-agent-bridge"
  fi
  if [[ -f "$APP_PATH/Contents/Resources/nool-dock-recovery" ]]; then
    /usr/bin/codesign --force --timestamp=none --sign "$SIGNING_IDENTITY" "$APP_PATH/Contents/Resources/nool-dock-recovery"
  fi
  if [[ -f "$APP_PATH/Contents/Resources/nool-media-remote-adapter.dylib" ]]; then
    /usr/bin/codesign --force --timestamp=none --sign "$SIGNING_IDENTITY" "$APP_PATH/Contents/Resources/nool-media-remote-adapter.dylib"
  fi
  if [[ -x "$COOLING_HELPER_PATH" ]]; then
    /usr/bin/codesign --force --timestamp=none --sign "$SIGNING_IDENTITY" \
      --identifier "$COOLING_HELPER_ID" "$COOLING_HELPER_PATH"
  fi
  record_signing_mode stable
  /usr/bin/codesign \
    --force \
    --timestamp=none \
    --sign "$SIGNING_IDENTITY" \
    "${APP_SIGNING_OPTIONS[@]}" \
    "$APP_PATH"
else
  if [[ -d "$WIDGET_PATH" ]]; then
    print -u2 'error: refusing ad-hoc signing of WidgetKit; rebuild without the extension or supply a team identity'
    exit 1
  fi
  if [[ "$ALLOW_ADHOC" != "1" ]]; then
    print -u2 -- "error: signing identity '$SIGNING_IDENTITY' is unavailable"
    print -u2 -- "error: refusing ad-hoc signing because it can reset Accessibility permission"
    print -u2 -- "error: set NOTCHAPP_ALLOW_ADHOC=1 only for an intentional temporary build"
    exit 1
  fi
  print -u2 -- "warning: signing identity '$SIGNING_IDENTITY' is unavailable; explicit ad-hoc signing enabled"
  record_signing_mode ad-hoc
  if [[ -x "$COOLING_HELPER_PATH" ]]; then
    /usr/bin/codesign --force --sign - --identifier "$COOLING_HELPER_ID" "$COOLING_HELPER_PATH"
  fi
  if [[ -f "$APP_PATH/Contents/Resources/nool-agent-bridge" ]]; then
    /usr/bin/codesign --force --sign - --identifier nool-agent-bridge \
      "$APP_PATH/Contents/Resources/nool-agent-bridge"
  fi
  if [[ -f "$APP_PATH/Contents/Resources/nool-dock-recovery" ]]; then
    /usr/bin/codesign --force --sign - --identifier nool-dock-recovery \
      "$APP_PATH/Contents/Resources/nool-dock-recovery"
  fi
  if [[ -f "$APP_PATH/Contents/Resources/nool-media-remote-adapter.dylib" ]]; then
    # --deep does not reach Mach-O files in Resources; perl loads this one.
    /usr/bin/codesign --force --sign - "$APP_PATH/Contents/Resources/nool-media-remote-adapter.dylib"
  fi
  /usr/bin/codesign \
    --force \
    --sign - \
    --requirements "$DESIGNATED_REQUIREMENT" \
    "$APP_PATH"
fi
