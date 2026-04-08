#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Quickey"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_DIR="$BUILD_DIR/${APP_NAME}.app"
INFO_PLIST="$PROJECT_DIR/Sources/Quickey/Resources/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
DMG_PATH="$BUILD_DIR/${APP_NAME}-${VERSION}.dmg"
VOLUME_NAME="$APP_NAME"
DMG_SIGN_IDENTITY="${DMG_SIGN_IDENTITY:-}"
STAGING_DIR=""

cleanup() {
    if [ -n "$STAGING_DIR" ] && [ -d "$STAGING_DIR" ]; then
        rm -rf "$STAGING_DIR"
    fi
}

trap cleanup EXIT

mkdir -p "$BUILD_DIR"

if [ ! -d "$APP_DIR" ]; then
    bash "$SCRIPT_DIR/package-app.sh"
fi

if [ ! -d "$APP_DIR" ]; then
    echo "Error: packaged app not found at $APP_DIR" >&2
    exit 1
fi

STAGING_DIR="$(mktemp -d "$BUILD_DIR/${APP_NAME}.dmg.staging.XXXXXX")"
rm -f "$DMG_PATH"

echo "==> Staging DMG contents..."
ditto "$APP_DIR" "$STAGING_DIR/${APP_NAME}.app"
ln -s /Applications "$STAGING_DIR/Applications"

echo "==> Creating DMG..."
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

if [ -n "$DMG_SIGN_IDENTITY" ]; then
    echo "==> Signing DMG with '$DMG_SIGN_IDENTITY'..."
    codesign --force --sign "$DMG_SIGN_IDENTITY" --timestamp "$DMG_PATH"
fi

echo "==> Done: $DMG_PATH"
