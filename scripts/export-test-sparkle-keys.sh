#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="${SPARKLE_KEY_OUTPUT_DIR:-$PROJECT_DIR/build/test-sparkle-keys}"
DEFAULT_ACCOUNT="wink-ci-$(uuidgen | tr '[:upper:]' '[:lower:]')"
SPARKLE_KEY_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-$DEFAULT_ACCOUNT}"
PUBLIC_KEY_PATH="$OUTPUT_DIR/public-ed-key.txt"
PRIVATE_KEY_PATH="$OUTPUT_DIR/private-ed-key.txt"

find_generate_keys() {
    find "$PROJECT_DIR/.build/artifacts" -path '*/bin/generate_keys' -type f -print -quit 2>/dev/null
}

GENERATE_KEYS_BIN="$(find_generate_keys)"
if [ -z "$GENERATE_KEYS_BIN" ]; then
    echo "Error: generate_keys not found in SwiftPM artifacts." >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
rm -f "$PUBLIC_KEY_PATH" "$PRIVATE_KEY_PATH"

"$GENERATE_KEYS_BIN" --account "$SPARKLE_KEY_ACCOUNT" >/dev/null
SPARKLE_PUBLIC_ED_KEY="$("$GENERATE_KEYS_BIN" --account "$SPARKLE_KEY_ACCOUNT" -p | tr -d '\n')"
"$GENERATE_KEYS_BIN" --account "$SPARKLE_KEY_ACCOUNT" -x "$PRIVATE_KEY_PATH" >/dev/null

printf '%s\n' "$SPARKLE_PUBLIC_ED_KEY" > "$PUBLIC_KEY_PATH"
chmod 600 "$PRIVATE_KEY_PATH"

printf 'SPARKLE_KEY_ACCOUNT=%s\n' "$SPARKLE_KEY_ACCOUNT"
printf 'SPARKLE_PUBLIC_ED_KEY=%s\n' "$SPARKLE_PUBLIC_ED_KEY"
printf 'SPARKLE_PUBLIC_ED_KEY_FILE=%s\n' "$PUBLIC_KEY_PATH"
printf 'SPARKLE_PRIVATE_ED_KEY_FILE=%s\n' "$PRIVATE_KEY_PATH"
