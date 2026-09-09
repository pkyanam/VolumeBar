#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-$PWD/dist/VolumeBar.app}"
BIN="$APP/Contents/MacOS/VolumeBar"
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --deep --strict "$APP"
[[ -x "$BIN" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")" == 14.4 ]]
[[ -n "$(/usr/libexec/PlistBuddy -c 'Print :NSAudioCaptureUsageDescription' "$APP/Contents/Info.plist")" ]]
ACTUAL="$(lipo -archs "$BIN")"
case "${ARCH:-arm64}" in
  arm64|x86_64) [[ "$ACTUAL" == "${ARCH:-arm64}" ]];;
  universal) [[ "$ACTUAL" == *arm64* && "$ACTUAL" == *x86_64* ]];;
esac
# No microphone/tap setup, UI, network request, or permission prompt in this mode.
"$BIN" --version
if [[ "${SIGNING_MODE:-adhoc}" == developer-id ]]; then
  DETAILS="$(codesign -dv --verbose=4 "$APP" 2>&1)"
  [[ "$DETAILS" == *'Authority=Developer ID Application:'* ]]
  [[ "$DETAILS" == *'runtime'* && "$DETAILS" == *'Timestamp='* ]]
  : "${APPLE_TEAM_ID:?Expected signing team is required}"
  [[ "$DETAILS" == *"TeamIdentifier=$APPLE_TEAM_ID"* ]]
fi
