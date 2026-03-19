#!/usr/bin/env bash
set -euo pipefail

APP_NAME="HotAppClone"
BUNDLE_ID="com.xrf9268.hotapp-clone"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_DIR="$BUILD_DIR/${APP_NAME}.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
INFO_PLIST="$PROJECT_DIR/Sources/HotAppClone/Resources/Info.plist"

echo "==> Building release binary..."
swift build -c release --package-path "$PROJECT_DIR"

BINARY="$PROJECT_DIR/.build/release/${APP_NAME}"
if [ ! -f "$BINARY" ]; then
    echo "Error: release binary not found at $BINARY" >&2
    exit 1
fi

echo "==> Creating app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# Copy binary
cp "$BINARY" "$MACOS_DIR/${APP_NAME}"
chmod +x "$MACOS_DIR/${APP_NAME}"

# Copy Info.plist from canonical source
if [ -f "$INFO_PLIST" ]; then
    cp "$INFO_PLIST" "$CONTENTS_DIR/Info.plist"
    echo "    Info.plist copied from Sources/HotAppClone/Resources/Info.plist"
else
    echo "Warning: Info.plist not found at $INFO_PLIST, generating default" >&2
    cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
fi

echo "==> Done: $APP_DIR"
echo "    Run with: open $APP_DIR"
