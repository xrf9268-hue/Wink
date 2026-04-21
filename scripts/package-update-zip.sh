#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Wink"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_DIR="$BUILD_DIR/${APP_NAME}.app"
INFO_PLIST="$PROJECT_DIR/Sources/Wink/Resources/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
ZIP_PATH="$BUILD_DIR/${APP_NAME}-${VERSION}.zip"

mkdir -p "$BUILD_DIR"

if [ ! -d "$APP_DIR" ]; then
    bash "$SCRIPT_DIR/package-app.sh"
fi

if [ ! -d "$APP_DIR" ]; then
    echo "Error: packaged app not found at $APP_DIR" >&2
    exit 1
fi

rm -f "$ZIP_PATH"

echo "==> Creating Sparkle update ZIP..."
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"

echo "==> Done: $ZIP_PATH"
