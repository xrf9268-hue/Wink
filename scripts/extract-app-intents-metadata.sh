#!/usr/bin/env bash

# SwiftPM does not run Xcode's App Intents metadata extraction phase. Build
# the one-file WinkIntents target for compiler constant metadata, then invoke
# the same Apple processor so the packaged .app is discoverable by Shortcuts.

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <app-binary> <resources-directory>" >&2
    exit 2
fi

APP_BINARY="$1"
RESOURCES_DIR="$2"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INTENTS_SOURCE="$PROJECT_DIR/Sources/WinkIntents/WinkAppIntents.swift"
PROTOCOLS_FILE="$SCRIPT_DIR/app-intents-const-protocols.json"

if [ ! -x "$APP_BINARY" ]; then
    echo "Error: executable app binary not found at $APP_BINARY" >&2
    exit 1
fi

if [ ! -f "$INTENTS_SOURCE" ] || [ ! -f "$PROTOCOLS_FILE" ]; then
    echo "Error: App Intents extraction inputs are missing" >&2
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

OBJECT_FILE="$SCRATCH_DIR/WinkAppIntents.o"
# swiftc's driver derives the const-values filename from the object output
# even when an explicit path is supplied, so keep both basenames identical.
CONST_VALUES="${OBJECT_FILE%.o}.swiftconstvalues"

"$SWIFTC" \
    -parse-as-library \
    -c "$INTENTS_SOURCE" \
    -module-name WinkIntents \
    -target "$TARGET_TRIPLE" \
    -sdk "$SDK_ROOT" \
    -emit-const-values \
    -Xfrontend -const-gather-protocols-file \
    -Xfrontend "$PROTOCOLS_FILE" \
    -emit-const-values-path "$CONST_VALUES" \
    -o "$OBJECT_FILE"

if [ ! -s "$CONST_VALUES" ]; then
    echo "Error: Swift compiler did not produce App Intents constant metadata" >&2
    exit 1
fi

printf '%s\n' "$INTENTS_SOURCE" > "$SCRATCH_DIR/sources.list"
printf '%s\n' "$CONST_VALUES" > "$SCRATCH_DIR/const-values.list"

"$PROCESSOR" \
    --output "$RESOURCES_DIR" \
    --toolchain-dir "$TOOLCHAIN_DIR" \
    --module-name WinkIntents \
    --sdk-root "$SDK_ROOT" \
    --xcode-version "$XCODE_BUILD_VERSION" \
    --platform-family macOS \
    --deployment-target 15.0 \
    --target-triple "$TARGET_TRIPLE" \
    --bundle-identifier com.wink.app \
    --binary-file "$APP_BINARY" \
    --stringsdata-file "$SCRATCH_DIR/ExtractedAppShortcutsMetadata.stringsdata" \
    --source-file-list "$SCRATCH_DIR/sources.list" \
    --swift-const-vals-list "$SCRATCH_DIR/const-values.list" \
    --compile-time-extraction \
    --deployment-aware-processing \
    --validate-assistant-intents

python3 - "$RESOURCES_DIR/Metadata.appintents/extract.actionsdata" "$RESOURCES_DIR" <<'PY'
import json
import pathlib
import plistlib
import sys

metadata_path = pathlib.Path(sys.argv[1])
resources = pathlib.Path(sys.argv[2])
if not metadata_path.is_file():
    raise SystemExit(f"Error: App Intents metadata was not produced at {metadata_path}")

metadata = json.loads(metadata_path.read_text())
expected_actions = {
    "PauseWinkIntent",
    "ResumeWinkIntent",
    "ShowWinkSearchPaletteIntent",
    "OpenWinkSettingsIntent",
}
actions = metadata.get("actions", {})
if set(actions) != expected_actions:
    raise SystemExit(f"Error: expected App Intents {sorted(expected_actions)}, got {sorted(actions)}")
# Xcode 26 normalizes the replacement `supportedModes` value to foreground
# dynamic (8) and writes openAppWhenRun=false in the metadata. Xcode 16 has no
# IntentModes API and emits the macOS 15-25 openAppWhenRun fallback instead.
if any(
    not actions[name].get("openAppWhenRun")
    and actions[name].get("supportedModes") != 8
    for name in expected_actions
):
    raise SystemExit("Error: every Wink App Intent must launch or foreground Wink")

shortcuts = metadata.get("autoShortcuts", [])
if len(shortcuts) != 4 or {item.get("actionIdentifier") for item in shortcuts} != expected_actions:
    raise SystemExit("Error: packaged App Shortcuts metadata is incomplete")
if any(not item.get("systemImageName") for item in shortcuts):
    raise SystemExit("Error: every packaged App Shortcut needs an SF Symbol")

expected_phrases = {
    "Pause ${applicationName}",
    "Resume ${applicationName}",
    "Search with ${applicationName}",
    "Open ${applicationName} settings",
}
phrases = {
    phrase["key"]
    for item in shortcuts
    for phrase in item.get("phraseTemplates", [])
}
if phrases != expected_phrases:
    raise SystemExit(f"Error: packaged App Shortcut phrases are incomplete: {sorted(phrases)}")

for locale in ("en", "zh-Hans"):
    table_path = resources / f"{locale}.lproj" / "AppShortcuts.strings"
    if not table_path.is_file():
        raise SystemExit(f"Error: missing {locale} App Shortcuts localization")
    with table_path.open("rb") as handle:
        table = plistlib.load(handle)
    if not expected_phrases.issubset(table):
        raise SystemExit(f"Error: incomplete {locale} App Shortcuts localization")

    localizable_path = resources / f"{locale}.lproj" / "Localizable.strings"
    with localizable_path.open("rb") as handle:
        localizable = plistlib.load(handle)
    expected_intent_copy = {
        "Pause Wink",
        "Resume Wink",
        "Show Wink Search Palette",
        "Open Wink Settings",
        "Open Wink Settings at ${tab}",
        "Wink shortcuts are paused.",
        "Wink manual pause is cleared.",
        "Wink Search Palette is open.",
        "Wink Settings is open.",
        "Wink could not pause shortcuts.",
        "Wink could not resume shortcuts.",
        "Wink could not show the Search Palette.",
        "Wink Settings is not ready yet. Please try again.",
        "Wink Settings did not become visible.",
    }
    if not expected_intent_copy.issubset(localizable):
        raise SystemExit(f"Error: incomplete {locale} App Intent copy localization")

print("    App Intents metadata verified: 4 actions, 4 localized App Shortcuts")
PY
