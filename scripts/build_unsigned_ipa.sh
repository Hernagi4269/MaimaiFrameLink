#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

BUILD_DIR="$ROOT_DIR/build"
DERIVED_DATA="$BUILD_DIR/DerivedData"
PAYLOAD_DIR="$BUILD_DIR/Payload"
IPA_PATH="$BUILD_DIR/MaimaiFrameLink.ipa"

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
if [[ ! -d "$APP_PATH" ]]; then
  echo "❌ Build succeeded but app bundle was not found: $APP_PATH" >&2
  exit 1
fi

mkdir -p "$PAYLOAD_DIR"
cp -R "$APP_PATH" "$PAYLOAD_DIR/"
(
  cd "$BUILD_DIR"
  /usr/bin/zip -qry "$(basename "$IPA_PATH")" Payload
)

echo "Unsigned IPA: $IPA_PATH"
