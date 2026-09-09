#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./Scripts/verify-app.sh
ARCH="${ARCH:-arm64}"
mkdir -p dist
ZIP="$PWD/dist/VolumeBar-$ARCH.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent dist/VolumeBar.app "$ZIP"
if [[ "${CREATE_DMG:-0}" == 1 ]]; then
  STAGE="$(mktemp -d "$PWD/dist/.dmg.XXXXXX")"
  trap 'rm -rf "$STAGE"' EXIT
  ditto dist/VolumeBar.app "$STAGE/VolumeBar.app"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname VolumeBar -srcfolder "$STAGE" -ov -format UDZO "dist/VolumeBar-$ARCH.dmg"
fi
(cd dist && shasum -a 256 "VolumeBar-$ARCH.zip" > SHA256SUMS.txt)
if [[ "${CREATE_DMG:-0}" == 1 ]]; then
  (cd dist && shasum -a 256 "VolumeBar-$ARCH.dmg" >> SHA256SUMS.txt)
fi
