#!/usr/bin/env bash

# SwiftPM does not run Xcode's App Intents metadata extraction phase for the
# embedded extension. Compile the extension-only Focus intent for constant
# metadata, then run Apple's processor against the actual extension binary.

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <extension-binary> <resources-directory>" >&2
    exit 2
fi

EXTENSION_BINARY="$1"
RESOURCES_DIR="$2"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INTENTS_SOURCE="$PROJECT_DIR/Sources/WinkFocusIntents/WinkFocusFilterIntent.swift"
PROTOCOLS_FILE="$SCRIPT_DIR/app-intents-const-protocols.json"
MODULES_DIR="$PROJECT_DIR/.build/release/Modules"

if [ ! -x "$EXTENSION_BINARY" ]; then
    echo "Error: executable Focus extension binary not found at $EXTENSION_BINARY" >&2
    exit 1
fi

if [ ! -f "$INTENTS_SOURCE" ] || [ ! -f "$PROTOCOLS_FILE" ]; then
    echo "Error: Focus App Intents extraction inputs are missing" >&2
    exit 1
fi

SWIFTC="$(xcrun --find swiftc)"
SDK_ROOT="$(xcrun --sdk macosx --show-sdk-path)"
TOOLCHAIN_DIR="$(cd "$(dirname "$SWIFTC")/../.." && pwd)"
XCODE_BUILD_VERSION="$(xcodebuild -version | awk '/Build version/{print $3}')"
TARGET_TRIPLE="$(swiftc -print-target-info | python3 -c 'import json, sys; print(json.load(sys.stdin)["target"]["triple"])')"
PROCESSOR="$(xcrun --find appintentsmetadataprocessor)"
SCRATCH_DIR="$(mktemp -d)"
trap 'rm -rf "$SCRATCH_DIR"' EXIT

OBJECT_FILE="$SCRATCH_DIR/WinkFocusFilterIntent.o"
CONST_VALUES="${OBJECT_FILE%.o}.swiftconstvalues"

"$SWIFTC" \
    -parse-as-library \
    -c "$INTENTS_SOURCE" \
    -module-name WinkFocusIntents \
    -target "$TARGET_TRIPLE" \
    -sdk "$SDK_ROOT" \
    -I "$MODULES_DIR" \
    -emit-const-values \
    -Xfrontend -const-gather-protocols-file \
    -Xfrontend "$PROTOCOLS_FILE" \
    -emit-const-values-path "$CONST_VALUES" \
    -o "$OBJECT_FILE"

if [ ! -s "$CONST_VALUES" ]; then
    echo "Error: Swift compiler did not produce Focus App Intents constant metadata" >&2
    exit 1
fi

printf '%s\n' "$INTENTS_SOURCE" > "$SCRATCH_DIR/sources.list"
printf '%s\n' "$CONST_VALUES" > "$SCRATCH_DIR/const-values.list"

"$PROCESSOR" \
    --output "$RESOURCES_DIR" \
    --toolchain-dir "$TOOLCHAIN_DIR" \
    --module-name WinkFocusIntents \
    --sdk-root "$SDK_ROOT" \
    --xcode-version "$XCODE_BUILD_VERSION" \
    --platform-family macOS \
    --deployment-target 15.0 \
    --target-triple "$TARGET_TRIPLE" \
    --bundle-identifier com.wink.app.focus-intents \
    --binary-file "$EXTENSION_BINARY" \
    --stringsdata-file "$SCRATCH_DIR/ExtractedFocusIntentsMetadata.stringsdata" \
    --source-file-list "$SCRATCH_DIR/sources.list" \
    --swift-const-vals-list "$SCRATCH_DIR/const-values.list" \
    --compile-time-extraction \
    --deployment-aware-processing \
    --validate-assistant-intents

python3 - "$RESOURCES_DIR/Metadata.appintents/extract.actionsdata" <<'PY'
import json
import pathlib
import sys

metadata_path = pathlib.Path(sys.argv[1])
if not metadata_path.is_file():
    raise SystemExit(f"Error: Focus App Intents metadata was not produced at {metadata_path}")

metadata = json.loads(metadata_path.read_text())
actions = metadata.get("actions", {})
if set(actions) != {"SetWinkFocusFilterIntent"}:
    raise SystemExit(f"Error: expected one Focus Filter intent, got {sorted(actions)}")

action = actions["SetWinkFocusFilterIntent"]
if action.get("isDiscoverable") is False:
    raise SystemExit("Error: packaged Focus Filter intent is not discoverable")

print("    Focus App Intents metadata verified: SetWinkFocusFilterIntent")
PY
