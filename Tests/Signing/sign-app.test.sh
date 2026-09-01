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
