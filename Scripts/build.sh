#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source version.env
CONFIG="${CONFIGURATION:-release}"
ARCH="${ARCH:-arm64}"
MODE="${SIGNING_MODE:-adhoc}"
case "$CONFIG" in release|debug) ;; *) echo 'Invalid CONFIGURATION' >&2; exit 1;; esac
case "$ARCH" in
  arm64|x86_64) ARCH_ARGS=(--arch "$ARCH");;
  universal) ARCH_ARGS=(--arch arm64 --arch x86_64);;
  *) echo 'ARCH must be arm64, x86_64, or universal' >&2; exit 1;;
esac
case "$MODE" in adhoc|developer-id) ;; *) echo 'Invalid SIGNING_MODE' >&2; exit 1;; esac
BUILD="${CI_BUILD_NUMBER:-$BUILD_NUMBER}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$BUILD" =~ ^[0-9]+$ ]] || exit 1
swift build -c "$CONFIG" "${ARCH_ARGS[@]}" -j 2
BIN_DIR="$(swift build -c "$CONFIG" "${ARCH_ARGS[@]}" --show-bin-path)"
# Stage a fresh bundle. Never reuse stale resources or signatures from a prior build.
mkdir -p dist
STAGE="$(mktemp -d "$PWD/dist/.bundle.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/VolumeBar.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/VolumeBar" "$APP/Contents/MacOS/VolumeBar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
if [[ "$MODE" == developer-id ]]; then
  : "${SIGNING_IDENTITY:?A Developer ID Application identity is required}"
  : "${SIGNING_KEYCHAIN:?An isolated signing keychain is required}"
  codesign --force --sign "$SIGNING_IDENTITY" --keychain "$SIGNING_KEYCHAIN" --options runtime --timestamp "$APP"
else
  codesign --force --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"
# Only replace our generated output, after staging and signing succeeded.
rm -rf "$PWD/dist/VolumeBar.app"
mv "$APP" "$PWD/dist/VolumeBar.app"
./Scripts/verify-app.sh
printf 'Built dist/VolumeBar.app (%s, %s)\n' "$ARCH" "$MODE"
