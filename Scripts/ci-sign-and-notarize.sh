#!/bin/bash
# Only run for trusted main/tag commits, on an ephemeral GitHub-hosted runner.
set -euo pipefail
set +x
cd "$(dirname "$0")/.."
[[ "${GITHUB_ACTIONS:-}" == true ]] || { echo 'Use the isolated CI runner for release signing.' >&2; exit 1; }
for NAME in DEVELOPER_ID_P12_BASE64 DEVELOPER_ID_P12_PASSWORD APPLE_API_KEY_P8 APPLE_API_KEY_ID APPLE_API_ISSUER_ID APPLE_TEAM_ID; do
  [[ -n "${!NAME:-}" ]] || { echo "Missing required secret: $NAME" >&2; exit 1; }
done
umask 077
SIGN_DIR="$RUNNER_TEMP/volumebar-signing"
mkdir -p "$SIGN_DIR"
export SIGNING_KEYCHAIN="$SIGN_DIR/signing.keychain-db"
KEYCHAIN_PASSWORD="$(openssl rand -hex 32)"
echo "::add-mask::$KEYCHAIN_PASSWORD"
cleanup() {
  security delete-keychain "$SIGNING_KEYCHAIN" >/dev/null 2>&1 || true
  rm -rf "$SIGN_DIR"
}
trap cleanup EXIT
printf '%s' "$DEVELOPER_ID_P12_BASE64" | base64 --decode > "$SIGN_DIR/certificate.p12"
printf '%s' "$APPLE_API_KEY_P8" > "$SIGN_DIR/AuthKey.p8"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$SIGNING_KEYCHAIN"
security set-keychain-settings -lut 7200 "$SIGNING_KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$SIGNING_KEYCHAIN"
security import "$SIGN_DIR/certificate.p12" -k "$SIGNING_KEYCHAIN" -P "$DEVELOPER_ID_P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$SIGNING_KEYCHAIN" >/dev/null
export SIGNING_IDENTITY
SIGNING_IDENTITY="$(security find-identity -v -p codesigning "$SIGNING_KEYCHAIN" | awk '/Developer ID Application:/ {print $2; exit}')"
[[ "$SIGNING_IDENTITY" =~ ^[A-Fa-f0-9]{40}$ ]] || { echo 'No valid Developer ID Application private key found.' >&2; exit 1; }
export SIGNING_MODE=developer-id
./Scripts/build.sh
mkdir -p artifacts
SUBMISSION="$RUNNER_TEMP/VolumeBar-notarization.zip"
ditto -c -k --sequesterRsrc --keepParent dist/VolumeBar.app "$SUBMISSION"
AUTH=(--key "$SIGN_DIR/AuthKey.p8" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID")
# Do not retry submissions blindly: a timeout may mean Apple is still processing it.
set +e
xcrun notarytool submit "$SUBMISSION" "${AUTH[@]}" --wait --timeout 20m --output-format json > artifacts/notarization.json
NOTARY_EXIT=$?
set -e
STATUS="$(python3 -c 'import json; print(json.load(open("artifacts/notarization.json")).get("status", "Unknown"))' 2>/dev/null || echo Unknown)"
if [[ "$STATUS" != Accepted || "$NOTARY_EXIT" != 0 ]]; then
  ID="$(python3 -c 'import json; print(json.load(open("artifacts/notarization.json")).get("id", ""))' 2>/dev/null || true)"
  if [[ -n "$ID" ]]; then
    xcrun notarytool log "$ID" "${AUTH[@]}" artifacts/notarization-log.json || true
  fi
  echo "Notarization did not complete successfully ($STATUS). No release will be published." >&2
  exit 1
fi
# Ticket propagation can lag acceptance. Retry stapling with a short bounded backoff.
STAPLED=0
for DELAY in 0 10 20 30; do
  sleep "$DELAY"
  if xcrun stapler staple dist/VolumeBar.app; then STAPLED=1; break; fi
done
[[ "$STAPLED" == 1 ]]
xcrun stapler validate dist/VolumeBar.app
./Scripts/verify-app.sh
spctl --assess --type execute --verbose=2 dist/VolumeBar.app
CREATE_DMG=1 ./Scripts/package.sh
# Sign, notarize and staple the outer disk image as well, for an offline-friendly installer.
codesign --force --sign "$SIGNING_IDENTITY" --keychain "$SIGNING_KEYCHAIN" --timestamp "dist/VolumeBar-${ARCH:-arm64}.dmg"
xcrun notarytool submit "dist/VolumeBar-${ARCH:-arm64}.dmg" "${AUTH[@]}" --wait --timeout 20m --output-format json > artifacts/dmg-notarization.json
python3 -c 'import json; assert json.load(open("artifacts/dmg-notarization.json"))["status"] == "Accepted"'
STAPLED=0
for DELAY in 0 10 20 30; do
  sleep "$DELAY"
  if xcrun stapler staple "dist/VolumeBar-${ARCH:-arm64}.dmg"; then STAPLED=1; break; fi
done
[[ "$STAPLED" == 1 ]]
xcrun stapler validate "dist/VolumeBar-${ARCH:-arm64}.dmg"
(cd dist && shasum -a 256 "VolumeBar-${ARCH:-arm64}.zip" "VolumeBar-${ARCH:-arm64}.dmg" > SHA256SUMS.txt)
