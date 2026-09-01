#!/bin/zsh
set -euo pipefail

VERSION="${1:?Usage: package-release.sh X.Y.Z}"
ARCH="${NOTCHAPP_RELEASE_ARCH:-arm64}"
PROJECT_ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
DIST_DIR="$PROJECT_ROOT/dist"
APP_PATH="$DIST_DIR/NotchApp.app"
ARCHIVE_NAME="NoolNotch-v${VERSION}-${ARCH}.zip"
ARCHIVE_PATH="$DIST_DIR/$ARCHIVE_NAME"
CHECKSUM_PATH="$ARCHIVE_PATH.sha256"

if ! print -r -- "$VERSION" | /usr/bin/grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z]+)*$'; then
  print -u2 -- "error: version must look like X.Y.Z"
  exit 2
fi

case "$ARCH" in
  arm64|x86_64) ;;
  *)
    print -u2 -- "error: unsupported release architecture '$ARCH'"
    exit 2
    ;;
esac

cd "$PROJECT_ROOT"

XCRUN="/usr/bin/xcrun"
"$XCRUN" swift build -c release --arch "$ARCH"
BIN_PATH="$("$XCRUN" swift build -c release --arch "$ARCH" --show-bin-path)"

/bin/rm -rf "$APP_PATH"
/bin/rm -f "$ARCHIVE_PATH" "$CHECKSUM_PATH"
/bin/mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
/usr/bin/install -m 755 "$BIN_PATH/NotchApp" "$APP_PATH/Contents/MacOS/NotchApp"
/bin/cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
/bin/cp "$PROJECT_ROOT/Resources/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${NOTCHAPP_BUILD_NUMBER:-1}" "$APP_PATH/Contents/Info.plist"

# Public artifacts stay intentionally ad-hoc signed until Developer ID and
# notarization are configured. The sentinel identity forces sign-app.sh into
# its explicit ad-hoc path even on a developer machine with a local certificate.
NOTCHAPP_SIGNING_IDENTITY="Nool Notch Release Ad-Hoc" \
NOTCHAPP_ALLOW_ADHOC=1 \
  "$PROJECT_ROOT/scripts/sign-app.sh" "$APP_PATH"

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE_PATH"
SHA256="$(/usr/bin/shasum -a 256 "$ARCHIVE_PATH" | /usr/bin/awk '{print $1}')"
print -r -- "$SHA256  $ARCHIVE_NAME" > "$CHECKSUM_PATH"

print -- "Created $ARCHIVE_PATH"
print -- "SHA-256 $SHA256"
