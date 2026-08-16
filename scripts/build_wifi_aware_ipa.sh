#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
BUILD_DIR="$ROOT_DIR/build-aware"
DERIVED_DATA="$BUILD_DIR/DerivedData"
PAYLOAD_DIR="$BUILD_DIR/Payload"
IPA_PATH="$BUILD_DIR/MaimaiFrameLink-WiFiAware.ipa"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

xcodebuild \
  -project MaimaiFrameLink.xcodeproj \
  -scheme MaimaiFrameLink \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build

APP_PATH="$DERIVED_DATA/Build/Products/Release-iphoneos/MaimaiFrameLink.app"
ENTITLEMENTS="$ROOT_DIR/MaimaiFrameLink/MaimaiFrameLink-WiFiAware.entitlements"
[[ -d "$APP_PATH" ]] || { echo "❌ App bundle not found"; exit 1; }
[[ -f "$ENTITLEMENTS" ]] || { echo "❌ Wi-Fi Aware entitlements missing"; exit 1; }

# Embed requested entitlements in an ad-hoc signature so a sideloading signer can inspect them.
/usr/bin/codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP_PATH"
/usr/bin/codesign -d --entitlements :- "$APP_PATH" 2>&1 || true

mkdir -p "$PAYLOAD_DIR"
cp -R "$APP_PATH" "$PAYLOAD_DIR/"
(
  cd "$BUILD_DIR"
  /usr/bin/zip -qry "$(basename "$IPA_PATH")" Payload
)

echo "✅ Wi-Fi Aware experimental IPA built: $IPA_PATH"
