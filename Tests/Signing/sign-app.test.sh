#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
SIGN_SCRIPT="$PROJECT_ROOT/scripts/sign-app.sh"
SIGNING_IDENTITY="${NOTCHAPP_SIGNING_IDENTITY:-Apple Development: Nail Ultyev (8SY5RA8Q5F)}"
TEST_ROOT="$(mktemp -d /private/tmp/notchapp-signing.XXXXXX)"
APP_PATH="$TEST_ROOT/NotchApp.app"

cleanup() {
  chmod -R u+w "$TEST_ROOT" 2>/dev/null || true
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
  print -u2 -- "FAIL: $1"
  exit 1
}

[[ -x "$SIGN_SCRIPT" ]] || fail "stable app signer is missing"

mkdir -p "$APP_PATH/Contents/MacOS"
cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"

cp /usr/bin/true "$APP_PATH/Contents/MacOS/NotchApp"
NOTCHAPP_SIGNING_IDENTITY="$SIGNING_IDENTITY" "$SIGN_SCRIPT" "$APP_PATH"
first_requirement="$(/usr/bin/codesign -d -r- "$APP_PATH" 2>&1)"
first_authority="$(/usr/bin/codesign -dvv "$APP_PATH" 2>&1)"

[[ "$first_authority" == *"Authority=$SIGNING_IDENTITY"* ]] \
  || fail "expected signing identity was not used: $first_authority"
first_mode="$(/usr/libexec/PlistBuddy -c 'Print :NotchAppSigningMode' "$APP_PATH/Contents/Info.plist")"
[[ "$first_mode" == "stable" ]] \
  || fail "identity-signed bundle did not record stable signing mode"

[[ "$first_requirement" == *'identifier "com.nailuyltyev.NotchApp"'* ]] \
  || fail "designated requirement is not based on the bundle identifier: $first_requirement"
[[ "$first_requirement" != *"cdhash"* ]] \
  || fail "designated requirement still depends on cdhash: $first_requirement"

cp /usr/bin/false "$APP_PATH/Contents/MacOS/NotchApp"
NOTCHAPP_SIGNING_IDENTITY="$SIGNING_IDENTITY" "$SIGN_SCRIPT" "$APP_PATH"
second_requirement="$(/usr/bin/codesign -d -r- "$APP_PATH" 2>&1)"

[[ "$second_requirement" == "$first_requirement" ]] \
  || fail "designated requirement changed after replacing the executable"
/usr/bin/codesign --verify --deep --strict "$APP_PATH"

cp /usr/bin/true "$APP_PATH/Contents/MacOS/NotchApp"
if NOTCHAPP_SIGNING_IDENTITY="NotchApp Missing Identity" \
  "$SIGN_SCRIPT" "$APP_PATH" 2>/dev/null; then
  fail "missing identity must not silently replace the stable signature"
fi

NOTCHAPP_SIGNING_IDENTITY="NotchApp Missing Identity" \
  NOTCHAPP_ALLOW_ADHOC=1 \
  "$SIGN_SCRIPT" "$APP_PATH"
adhoc_signature="$(/usr/bin/codesign -dvv "$APP_PATH" 2>&1)"
[[ "$adhoc_signature" == *"Signature=adhoc"* ]] \
  || fail "explicit ad-hoc opt-in did not create an ad-hoc signature"
adhoc_mode="$(/usr/libexec/PlistBuddy -c 'Print :NotchAppSigningMode' "$APP_PATH/Contents/Info.plist")"
[[ "$adhoc_mode" == "ad-hoc" ]] \
  || fail "ad-hoc bundle did not record its unstable signing mode"
/usr/bin/codesign --verify --deep --strict "$APP_PATH"

print -- "PASS: local identity keeps a stable designated requirement"

# A widget must retain its sandbox and shared group when its containing app is re-signed.
TEAM_ID="$(/usr/bin/security find-certificate -c "$SIGNING_IDENTITY" -p | /usr/bin/openssl x509 -noout -subject -nameopt sep_multiline | /usr/bin/sed -n 's/^[[:space:]]*OU=//p')"
GROUP_ID="$TEAM_ID.com.nailuyltyev.NotchApp.widgets"
WIDGET_PATH="$APP_PATH/Contents/PlugIns/NoolQuotaWidget.appex"
mkdir -p "$WIDGET_PATH/Contents/MacOS"
cp /usr/bin/true "$WIDGET_PATH/Contents/MacOS/NoolQuotaWidget"
cp "$PROJECT_ROOT/Resources/Info.plist" "$WIDGET_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.nailuyltyev.NotchApp.NoolQuotaWidget' "$WIDGET_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable NoolQuotaWidget' "$WIDGET_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundlePackageType XPC!' "$WIDGET_PATH/Contents/Info.plist"
for BUNDLE in "$APP_PATH" "$WIDGET_PATH"; do
  /usr/libexec/PlistBuddy -c "Add :NoolWidgetAppGroup string $GROUP_ID" "$BUNDLE/Contents/Info.plist"
done
NOTCHAPP_SIGNING_IDENTITY="$SIGNING_IDENTITY" "$SIGN_SCRIPT" "$APP_PATH"
/usr/bin/codesign --verify --deep --strict "$APP_PATH"
for BUNDLE in "$APP_PATH" "$WIDGET_PATH"; do
  /usr/bin/codesign -d --entitlements - --xml "$BUNDLE" > "$TEST_ROOT/entitlements.plist" 2>/dev/null
  FOUND_GROUP="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$TEST_ROOT/entitlements.plist")"
  [[ "$FOUND_GROUP" == "$GROUP_ID" ]] || fail 'shared group was not preserved'
done
SANDBOX="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$TEST_ROOT/entitlements.plist")"
[[ "$SANDBOX" == true ]] || fail 'widget sandbox entitlement was not preserved'
if NOTCHAPP_SIGNING_IDENTITY='NotchApp Missing Identity' NOTCHAPP_ALLOW_ADHOC=1 "$SIGN_SCRIPT" "$APP_PATH" 2>/dev/null; then
  fail 'widget must not silently accept ad-hoc signing'
fi
/usr/libexec/PlistBuddy -c 'Set :NoolWidgetAppGroup WRONGTEAM0.com.nailuyltyev.NotchApp.widgets' "$WIDGET_PATH/Contents/Info.plist"
if NOTCHAPP_SIGNING_IDENTITY="$SIGNING_IDENTITY" "$SIGN_SCRIPT" "$APP_PATH" 2>/dev/null; then
  fail 'mismatched widget group must not be signed'
fi
NOTCHAPP_WIDGET_MODE=disabled "$PROJECT_ROOT/scripts/embed-widget.sh" "$APP_PATH"
[[ ! -d "$WIDGET_PATH" ]] || fail 'disabled widget was not removed from assembly'
if /usr/libexec/PlistBuddy -c 'Print :NoolWidgetAppGroup' "$APP_PATH/Contents/Info.plist" >/dev/null 2>&1; then
  fail 'disabled widget left an app group in the assembly'
fi
print -- 'PASS: nested widget signing preserves sandbox/group and rejects ad-hoc or mismatched groups'
