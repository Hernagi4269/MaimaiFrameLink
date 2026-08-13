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

INFO_PLIST="$APP_PATH/Info.plist"
if [[ ! -f "$INFO_PLIST" ]]; then
  echo "❌ Info.plist was not found in app bundle: $INFO_PLIST" >&2
  exit 1
fi

EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST" 2>/dev/null || true)"
if [[ -z "$EXECUTABLE_NAME" ]]; then
  echo "❌ CFBundleExecutable is missing from built Info.plist." >&2
  /usr/bin/plutil -p "$INFO_PLIST" || true
  exit 1
fi

EXECUTABLE_PATH="$APP_PATH/$EXECUTABLE_NAME"
if [[ ! -f "$EXECUTABLE_PATH" ]]; then
  echo "❌ App executable declared by CFBundleExecutable was not found: $EXECUTABLE_PATH" >&2
  /bin/ls -la "$APP_PATH" || true
  exit 1
fi

if [[ ! -x "$EXECUTABLE_PATH" ]]; then
  echo "❌ App executable exists but is not executable: $EXECUTABLE_PATH" >&2
  /bin/ls -l "$EXECUTABLE_PATH" || true
  exit 1
fi

echo "✅ App bundle validation passed"
echo "   CFBundleExecutable: $EXECUTABLE_NAME"
echo "   Executable: $EXECUTABLE_PATH"

mkdir -p "$PAYLOAD_DIR"
cp -R "$APP_PATH" "$PAYLOAD_DIR/"
(
  cd "$BUILD_DIR"
  /usr/bin/zip -qry "$(basename "$IPA_PATH")" Payload
)

VERIFY_DIR="$BUILD_DIR/verify-ipa"
mkdir -p "$VERIFY_DIR"
/usr/bin/unzip -q "$IPA_PATH" -d "$VERIFY_DIR"
VERIFIED_APP="$VERIFY_DIR/Payload/MaimaiFrameLink.app"
VERIFIED_PLIST="$VERIFIED_APP/Info.plist"
VERIFIED_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$VERIFIED_PLIST" 2>/dev/null || true)"

if [[ -z "$VERIFIED_EXECUTABLE" || ! -x "$VERIFIED_APP/$VERIFIED_EXECUTABLE" ]]; then
  echo "❌ IPA post-package validation failed." >&2
  /bin/ls -la "$VERIFIED_APP" || true
  /usr/bin/plutil -p "$VERIFIED_PLIST" || true
  exit 1
fi

echo "✅ IPA post-package validation passed"
echo "Unsigned IPA: $IPA_PATH"
