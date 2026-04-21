#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Wink"
BUNDLE_ID="com.wink.app"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_DIR="$BUILD_DIR/${APP_NAME}.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
INFO_PLIST="$PROJECT_DIR/Sources/Wink/Resources/Info.plist"
APP_ICON="$PROJECT_DIR/Sources/Wink/Resources/AppIcon.icns"
SIGN_IDENTITY="${SIGN_IDENTITY:-Wink}"
ENTITLEMENTS_PLIST="${ENTITLEMENTS_PLIST:-$PROJECT_DIR/entitlements.plist}"
ENABLE_HARDENED_RUNTIME="${ENABLE_HARDENED_RUNTIME:-0}"
ENABLE_TIMESTAMP="${ENABLE_TIMESTAMP:-0}"
REQUIRE_SIGN_IDENTITY="${REQUIRE_SIGN_IDENTITY:-0}"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"

find_sparkle_framework() {
    local -a candidates=()
    local xcframework_plist=""

    while IFS= read -r xcframework_plist; do
        local candidate=""
        candidate="$(python3 - "$xcframework_plist" <<'PY'
import plistlib
import pathlib
import sys

plist_path = pathlib.Path(sys.argv[1])
with plist_path.open('rb') as handle:
    info = plistlib.load(handle)

for library in info.get("AvailableLibraries", []):
    if library.get("SupportedPlatform") == "macos":
        print(plist_path.parent / library["LibraryIdentifier"] / library["LibraryPath"])
        break
PY
)"

        if [ -n "$candidate" ] && [ -d "$candidate" ]; then
            candidates+=("$candidate")
        fi
    done < <(find "$PROJECT_DIR/.build/artifacts" -path '*/Sparkle.xcframework/Info.plist' -type f 2>/dev/null | sort)

    if [ "${#candidates[@]}" -gt 1 ]; then
        echo "Error: multiple macOS Sparkle.framework candidates found in SwiftPM artifacts." >&2
        printf '  %s\n' "${candidates[@]}" >&2
        return 1
    fi

    if [ "${#candidates[@]}" -eq 1 ]; then
        printf '%s\n' "${candidates[0]}"
    fi
}

apply_sparkle_info_overrides() {
    local plist_path="$1"

    if [ -n "$SPARKLE_FEED_URL" ]; then
        plutil -replace SUFeedURL -string "$SPARKLE_FEED_URL" "$plist_path"
    fi

    if [ -n "$SPARKLE_PUBLIC_ED_KEY" ]; then
        plutil -replace SUPublicEDKey -string "$SPARKLE_PUBLIC_ED_KEY" "$plist_path"
    fi
}

sign_nested_item() {
    local path="$1"
    local -a args=(--force --sign "$SELECTED_SIGN_IDENTITY")

    if [ "$ENABLE_HARDENED_RUNTIME" = "1" ] && [ "$SELECTED_SIGN_IDENTITY" != "-" ]; then
        args+=(--options runtime)
    fi

    if [ "$ENABLE_TIMESTAMP" = "1" ] && [ "$SELECTED_SIGN_IDENTITY" != "-" ]; then
        args+=(--timestamp)
    fi

    codesign "${args[@]}" "$path" 2>&1
}

echo "==> Building release binary..."
swift build -c release --package-path "$PROJECT_DIR"

BINARY="$PROJECT_DIR/.build/release/${APP_NAME}"
if [ ! -f "$BINARY" ]; then
    echo "Error: release binary not found at $BINARY" >&2
    exit 1
fi

if ! SPARKLE_FRAMEWORK_SOURCE="$(find_sparkle_framework)"; then
    exit 1
fi

if [ -z "$SPARKLE_FRAMEWORK_SOURCE" ]; then
    echo "Error: Sparkle.framework not found in SwiftPM artifacts. Build may not have resolved the Sparkle package." >&2
    exit 1
fi

echo "==> Creating app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR"

# Copy binary
cp "$BINARY" "$MACOS_DIR/${APP_NAME}"
chmod +x "$MACOS_DIR/${APP_NAME}"

# Copy app icon into the bundle
if [ -f "$APP_ICON" ]; then
    cp "$APP_ICON" "$RESOURCES_DIR/AppIcon.icns"
    echo "    AppIcon.icns copied to Resources"
else
    echo "Warning: AppIcon.icns not found at $APP_ICON" >&2
fi

# Copy Info.plist from canonical source
if [ -f "$INFO_PLIST" ]; then
    cp "$INFO_PLIST" "$CONTENTS_DIR/Info.plist"
    apply_sparkle_info_overrides "$CONTENTS_DIR/Info.plist"
    echo "    Info.plist copied from Sources/Wink/Resources/Info.plist"
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
    apply_sparkle_info_overrides "$CONTENTS_DIR/Info.plist"
fi

# Copy Sparkle.framework into the app bundle while preserving symlinks.
echo "==> Embedding Sparkle.framework..."
ditto "$SPARKLE_FRAMEWORK_SOURCE" "$FRAMEWORKS_DIR/Sparkle.framework"

# Wink is not sandboxed, so it does not need Sparkle's XPC services.
rm -rf \
    "$FRAMEWORKS_DIR/Sparkle.framework/Versions/B/XPCServices" \
    "$FRAMEWORKS_DIR/Sparkle.framework/XPCServices"

# Sign with a stable identity if available; fall back to ad-hoc.
# A stable identity (e.g. "Wink Dev" self-signed cert) lets TCC
# permissions survive across rebuilds. Create one via:
#   Keychain Access → Certificate Assistant → Create a Certificate
#   Name: "Wink Dev", Type: Code Signing
if security find-identity -v -p codesigning 2>/dev/null | grep -Fq "$SIGN_IDENTITY"; then
    echo "==> Signing with '$SIGN_IDENTITY'..."
    SELECTED_SIGN_IDENTITY="$SIGN_IDENTITY"
else
    if [ "$REQUIRE_SIGN_IDENTITY" = "1" ]; then
        echo "Error: required signing identity '$SIGN_IDENTITY' was not found" >&2
        exit 1
    fi

    echo "==> Ad-hoc signing app bundle (no '$SIGN_IDENTITY' cert found)."
    echo "    TCC permissions may need re-granting after each rebuild."
    echo "    If System Settings still shows 'Wink' but this build logs ax=false/im=false,"
    echo "    remove the stale row and re-add: $APP_DIR"
    echo "    To fix: create a self-signed cert named '$SIGN_IDENTITY' in Keychain Access."
    SELECTED_SIGN_IDENTITY="-"
fi

SPARKLE_FRAMEWORK_DIR="$FRAMEWORKS_DIR/Sparkle.framework"

echo "==> Signing embedded Sparkle components..."
if [ -e "$SPARKLE_FRAMEWORK_DIR/Versions/B/Autoupdate" ]; then
    sign_nested_item "$SPARKLE_FRAMEWORK_DIR/Versions/B/Autoupdate"
fi

if [ -d "$SPARKLE_FRAMEWORK_DIR/Versions/B/Updater.app" ]; then
    sign_nested_item "$SPARKLE_FRAMEWORK_DIR/Versions/B/Updater.app"
fi

sign_nested_item "$SPARKLE_FRAMEWORK_DIR"

echo "==> Signing app bundle..."
SIGN_ARGS=(--force --sign "$SELECTED_SIGN_IDENTITY" --identifier "$BUNDLE_ID")

if [ "$ENABLE_HARDENED_RUNTIME" = "1" ] && [ "$SELECTED_SIGN_IDENTITY" != "-" ]; then
    SIGN_ARGS+=(--options runtime)
    if [ ! -f "$ENTITLEMENTS_PLIST" ]; then
        echo "Error: entitlements file not found at $ENTITLEMENTS_PLIST" >&2
        exit 1
    fi
    SIGN_ARGS+=(--entitlements "$ENTITLEMENTS_PLIST")
fi

if [ "$ENABLE_TIMESTAMP" = "1" ] && [ "$SELECTED_SIGN_IDENTITY" != "-" ]; then
    SIGN_ARGS+=(--timestamp)
fi

codesign "${SIGN_ARGS[@]}" "$APP_DIR" 2>&1

echo "==> Done: $APP_DIR"
echo "    Run with: open $APP_DIR"
