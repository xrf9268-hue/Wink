#!/usr/bin/env bash
# Compiles the hand-authored String Catalogs into the checked-in per-locale
# .lproj files under
# Sources/Wink/Resources/Localized.
#
# `swift build` does not compile .xcstrings — Xcode's build system does that
# via an auto-extraction phase that SwiftPM's plain `swift build` never runs.
# Left uncompiled, the raw .xcstrings file would just be copied into the
# resource bundle as dead weight: even the English values would not resolve,
# and every lookup key would fall through verbatim. Compiling ahead of time
# and checking in the result keeps `swift build`/`swift test` correct on any
# machine, including ones without Xcode.
#
# Usage:
#   scripts/gen-localizations.sh          # regenerate Sources/Wink/Resources/Localized
#   scripts/gen-localizations.sh --check  # verify the checked-in output is up to date (CI)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOGS=(
  "$REPO_ROOT/Sources/Wink/Resources/Localizable.xcstrings"
  "$REPO_ROOT/Sources/Wink/Resources/AppShortcuts.xcstrings"
)
OUTPUT_DIR="$REPO_ROOT/Sources/Wink/Resources/Localized"

MODE="generate"
if [ "${1:-}" = "--check" ]; then
  MODE="check"
fi

for catalog in "${CATALOGS[@]}"; do
  if [ ! -f "$catalog" ]; then
    echo "error: missing $catalog" >&2
    exit 1
  fi
done

if ! command -v xcrun >/dev/null 2>&1; then
  echo "error: xcrun not found — this script requires Xcode command line tools on macOS" >&2
  exit 1
fi

compile_into() {
  local dest="$1"
  rm -rf "$dest"
  mkdir -p "$dest"
  for catalog in "${CATALOGS[@]}"; do
    xcrun xcstringstool compile "$catalog" --output-directory "$dest"
  done
}

if [ "$MODE" = "generate" ]; then
  compile_into "$OUTPUT_DIR"
  echo "Compiled ${#CATALOGS[@]} String Catalogs -> $OUTPUT_DIR"
  exit 0
fi

# --check: compile into a scratch directory and diff against the checked-in
# output so CI catches a String Catalog edit that was never
# regenerated.
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

compile_into "$TMP_DIR/Localized"

if ! diff -rq "$TMP_DIR/Localized" "$OUTPUT_DIR" >"$TMP_DIR/diff.txt" 2>&1; then
  echo "error: $OUTPUT_DIR is out of date with the String Catalog sources" >&2
  echo "" >&2
  cat "$TMP_DIR/diff.txt" >&2
  echo "" >&2
  echo "Run: bash scripts/gen-localizations.sh" >&2
  echo "then commit the regenerated files under Sources/Wink/Resources/Localized." >&2
  exit 1
fi

echo "Sources/Wink/Resources/Localized is up to date with ${#CATALOGS[@]} String Catalogs"
