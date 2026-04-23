#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Wink"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_DIR="$BUILD_DIR/${APP_NAME}.app"
INFO_PLIST="$PROJECT_DIR/Sources/Wink/Resources/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
DMG_PATH="$BUILD_DIR/${APP_NAME}-${VERSION}.dmg"
RW_DMG_PATH="$BUILD_DIR/${APP_NAME}-${VERSION}-layout.tmp.dmg"
BACKGROUND_SOURCE="$PROJECT_DIR/assets/dmg/wink-dmg-background.png"
BACKGROUND_NAME="background.png"
VOLUME_NAME="$APP_NAME"
DMG_SIGN_IDENTITY="${DMG_SIGN_IDENTITY:-}"
WINDOW_POS_X=160
WINDOW_POS_Y=120
WINDOW_WIDTH=640
WINDOW_HEIGHT=440
ICON_SIZE=104
TEXT_SIZE=13
APP_ICON_X=172
APP_ICON_Y=214
APPLICATIONS_X=468
APPLICATIONS_Y=214
APPLE_SCRIPT_DELAY="${DMG_APPLESCRIPT_DELAY:-2}"

APPLESCRIPT_FILE=""
DEVICE_NAME=""
MOUNT_DIR=""
STAGING_DIR=""
MOUNTED_VOLUME_NAME=""

detach_device() {
    local target="$1"
    local attempt=1

    while [ "$attempt" -le 5 ]; do
        if hdiutil detach "$target" >/dev/null 2>&1; then
            return 0
        fi
        sleep "$attempt"
        attempt=$((attempt + 1))
    done

    hdiutil detach -force "$target" >/dev/null 2>&1 || true
}

cleanup() {
    if [ -n "$DEVICE_NAME" ]; then
        detach_device "$DEVICE_NAME"
    elif [ -n "$MOUNT_DIR" ] && [ -d "$MOUNT_DIR" ]; then
        hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
    fi

    rm -f "$APPLESCRIPT_FILE" "$RW_DMG_PATH"

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

if [ ! -f "$BACKGROUND_SOURCE" ]; then
    echo "Error: DMG background asset not found at $BACKGROUND_SOURCE" >&2
    exit 1
fi

if mount | grep -Fq "on /Volumes/$VOLUME_NAME "; then
    echo "==> Detaching pre-existing /Volumes/$VOLUME_NAME mount..."
    detach_device "/Volumes/$VOLUME_NAME"
fi

STAGING_DIR="$(mktemp -d "$BUILD_DIR/${APP_NAME}.dmg.staging.XXXXXX")"
mkdir -p "$STAGING_DIR/.background"
rm -f "$DMG_PATH" "$RW_DMG_PATH"

echo "==> Staging DMG contents..."
ditto "$APP_DIR" "$STAGING_DIR/${APP_NAME}.app"
ln -s /Applications "$STAGING_DIR/Applications"
cp "$BACKGROUND_SOURCE" "$STAGING_DIR/.background/$BACKGROUND_NAME"
chflags hidden "$STAGING_DIR/.background"

STAGING_SIZE_MB=$(( ( $(du -sk "$STAGING_DIR" | awk '{print $1}') / 1024 ) + 96 ))

echo "==> Creating writable DMG template..."
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDRW \
    -fs HFS+ \
    -size "${STAGING_SIZE_MB}m" \
    "$RW_DMG_PATH"

echo "==> Mounting writable DMG..."
ATTACH_OUTPUT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG_PATH")"
DEVICE_NAME="$(printf '%s\n' "$ATTACH_OUTPUT" | awk '/\/Volumes\// {print $1}' | tail -n 1)"
MOUNT_DIR="$(printf '%s\n' "$ATTACH_OUTPUT" | awk '/\/Volumes\// {print $NF}' | tail -n 1)"

if [ -z "$DEVICE_NAME" ] || [ -z "$MOUNT_DIR" ]; then
    echo "Error: failed to determine mounted DMG device or mount path" >&2
    printf '%s\n' "$ATTACH_OUTPUT" >&2
    exit 1
fi

MOUNTED_VOLUME_NAME="$(basename "$MOUNT_DIR")"
chflags hidden "$MOUNT_DIR/.background" || true

APPLESCRIPT_FILE="$(mktemp "$BUILD_DIR/package-dmg.XXXXXX.applescript")"
cat > "$APPLESCRIPT_FILE" <<EOF
on run argv
    set volumeName to item 1 of argv
    tell application "Finder"
        tell disk volumeName
            open

            set theXOrigin to $WINDOW_POS_X
            set theYOrigin to $WINDOW_POS_Y
            set theWidth to $WINDOW_WIDTH
            set theHeight to $WINDOW_HEIGHT

            set theBottomRightX to (theXOrigin + theWidth)
            set theBottomRightY to (theYOrigin + theHeight)
            set dsStorePath to "/Volumes/" & volumeName & "/.DS_Store"

            tell container window
                set current view to icon view
                set toolbar visible to false
                set statusbar visible to false
                try
                    set pathbar visible to false
                end try
                set the bounds to {theXOrigin, theYOrigin, theBottomRightX, theBottomRightY}
            end tell

            set opts to the icon view options of container window
            tell opts
                set arrangement to not arranged
                set icon size to $ICON_SIZE
                set text size to $TEXT_SIZE
            end tell
            set background picture of opts to file ".background:$BACKGROUND_NAME"

            set the extension hidden of item "$APP_NAME.app" to true
            set position of item "$APP_NAME.app" to {$APP_ICON_X, $APP_ICON_Y}
            set position of item "Applications" to {$APPLICATIONS_X, $APPLICATIONS_Y}

            close
            open
            delay 1

            tell container window
                set statusbar visible to false
                try
                    set pathbar visible to false
                end try
                set the bounds to {theXOrigin, theYOrigin, theBottomRightX - 10, theBottomRightY - 10}
            end tell
        end tell

        delay 1

        tell disk volumeName
            tell container window
                set statusbar visible to false
                try
                    set pathbar visible to false
                end try
                set the bounds to {theXOrigin, theYOrigin, theBottomRightX, theBottomRightY}
            end tell
        end tell

        set waitTime to 0
        repeat while waitTime is less than 10
            if (do shell script "[ -f " & quoted form of dsStorePath & " ]; echo $?") = "0" then
                exit repeat
            end if
            delay 1
            set waitTime to waitTime + 1
        end repeat

        delay 1
    end tell
end run
EOF

echo "==> Configuring Finder window layout..."
sleep "$APPLE_SCRIPT_DELAY"
/usr/bin/osascript "$APPLESCRIPT_FILE" "$MOUNTED_VOLUME_NAME"

echo "==> Finalizing DMG..."
chmod -Rf go-w "$MOUNT_DIR" >/dev/null 2>&1 || true
sync
detach_device "$DEVICE_NAME"
DEVICE_NAME=""
MOUNT_DIR=""

hdiutil convert \
    "$RW_DMG_PATH" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG_PATH"

if [ -n "$DMG_SIGN_IDENTITY" ]; then
    echo "==> Signing DMG with '$DMG_SIGN_IDENTITY'..."
    codesign --force --sign "$DMG_SIGN_IDENTITY" --timestamp "$DMG_PATH"
fi

echo "==> Done: $DMG_PATH"
