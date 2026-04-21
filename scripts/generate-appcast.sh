#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Wink"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
INFO_PLIST="$PROJECT_DIR/Sources/Wink/Resources/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
ZIP_PATH="$BUILD_DIR/${APP_NAME}-${VERSION}.zip"
APPCAST_PATH="$BUILD_DIR/appcast.xml"
SPARKLE_PUBLIC_BASE_URL="${SPARKLE_PUBLIC_BASE_URL:-}"
SPARKLE_RELEASE_NOTES_FILE="${SPARKLE_RELEASE_NOTES_FILE:-}"
SPARKLE_FULL_RELEASE_NOTES_URL="${SPARKLE_FULL_RELEASE_NOTES_URL:-}"
SPARKLE_PRODUCT_LINK="${SPARKLE_PRODUCT_LINK:-}"
SPARKLE_PRIVATE_ED_KEY_FILE="${SPARKLE_PRIVATE_ED_KEY_FILE:-}"
SPARKLE_PRIVATE_ED_KEY="${SPARKLE_PRIVATE_ED_KEY:-}"
STAGING_DIR=""

cleanup() {
    if [ -n "$STAGING_DIR" ] && [ -d "$STAGING_DIR" ]; then
        rm -rf "$STAGING_DIR"
    fi
}

trap cleanup EXIT

find_generate_appcast() {
    find "$PROJECT_DIR/.build/artifacts" -path '*/bin/generate_appcast' -type f -print -quit 2>/dev/null
}

if [ -z "$SPARKLE_PUBLIC_BASE_URL" ]; then
    echo "Error: SPARKLE_PUBLIC_BASE_URL must point to the public update directory." >&2
    exit 1
fi

SPARKLE_PUBLIC_BASE_URL="$(printf '%s' "$SPARKLE_PUBLIC_BASE_URL" | sed 's#/*$#/#')"

if [ ! -f "$ZIP_PATH" ]; then
    bash "$SCRIPT_DIR/package-update-zip.sh"
fi

if [ ! -f "$ZIP_PATH" ]; then
    echo "Error: update ZIP not found at $ZIP_PATH" >&2
    exit 1
fi

GENERATE_APPCAST_BIN="$(find_generate_appcast)"
if [ -z "$GENERATE_APPCAST_BIN" ]; then
    echo "Error: generate_appcast not found in SwiftPM artifacts." >&2
    exit 1
fi

STAGING_DIR="$(mktemp -d "$BUILD_DIR/sparkle-updates.XXXXXX")"
cp "$ZIP_PATH" "$STAGING_DIR/$(basename "$ZIP_PATH")"

if [ -n "$SPARKLE_RELEASE_NOTES_FILE" ]; then
    if [ ! -f "$SPARKLE_RELEASE_NOTES_FILE" ]; then
        echo "Error: SPARKLE_RELEASE_NOTES_FILE does not exist: $SPARKLE_RELEASE_NOTES_FILE" >&2
        exit 1
    fi

    release_notes_ext="${SPARKLE_RELEASE_NOTES_FILE##*.}"
    cp "$SPARKLE_RELEASE_NOTES_FILE" "$STAGING_DIR/${APP_NAME}-${VERSION}.${release_notes_ext}"
fi

APPCAST_CMD=(
    "$GENERATE_APPCAST_BIN"
    --maximum-deltas 0
    --download-url-prefix "$SPARKLE_PUBLIC_BASE_URL"
    --release-notes-url-prefix "$SPARKLE_PUBLIC_BASE_URL"
    -o "$APPCAST_PATH"
)

if [ -n "$SPARKLE_FULL_RELEASE_NOTES_URL" ]; then
    APPCAST_CMD+=(--full-release-notes-url "$SPARKLE_FULL_RELEASE_NOTES_URL")
fi

if [ -n "$SPARKLE_PRODUCT_LINK" ]; then
    APPCAST_CMD+=(--link "$SPARKLE_PRODUCT_LINK")
fi

if [ -n "$SPARKLE_PRIVATE_ED_KEY_FILE" ]; then
    APPCAST_CMD+=(--ed-key-file "$SPARKLE_PRIVATE_ED_KEY_FILE")
    APPCAST_CMD+=("$STAGING_DIR")
    "${APPCAST_CMD[@]}"
elif [ -n "$SPARKLE_PRIVATE_ED_KEY" ]; then
    APPCAST_CMD+=(--ed-key-file -)
    APPCAST_CMD+=("$STAGING_DIR")
    printf '%s\n' "$SPARKLE_PRIVATE_ED_KEY" | "${APPCAST_CMD[@]}"
else
    APPCAST_CMD+=("$STAGING_DIR")
    "${APPCAST_CMD[@]}"
fi

echo "==> Done: $APPCAST_PATH"
