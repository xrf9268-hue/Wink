#!/usr/bin/env bash
# Compiles Sources/Wink/Resources/Localizable.xcstrings (the hand-authored
# source of truth) into the checked-in per-locale .lproj files under
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
CATALOG="$REPO_ROOT/Sources/Wink/Resources/Localizable.xcstrings"
OUTPUT_DIR="$REPO_ROOT/Sources/Wink/Resources/Localized"

MODE="generate"
if [ "${1:-}" = "--check" ]; then
  MODE="check"
fi

if [ ! -f "$CATALOG" ]; then
  echo "error: missing $CATALOG" >&2
  exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
  echo "error: xcrun not found — this script requires Xcode command line tools on macOS" >&2
  exit 1
fi

compile_into() {
  local dest="$1"
  rm -rf "$dest"
  mkdir -p "$dest"
  xcrun xcstringstool compile "$CATALOG" --output-directory "$dest"
}

if [ "$MODE" = "generate" ]; then
  compile_into "$OUTPUT_DIR"
  echo "Compiled $CATALOG -> $OUTPUT_DIR"
  exit 0
fi

# --check: compile into a scratch directory and diff against the checked-in
# output so CI catches a Localizable.xcstrings edit that was never
# regenerated.
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

compile_into "$TMP_DIR/Localized"

if ! diff -rq "$TMP_DIR/Localized" "$OUTPUT_DIR" >"$TMP_DIR/diff.txt" 2>&1; then
  echo "error: $OUTPUT_DIR is out of date with $CATALOG" >&2
  echo "" >&2
  cat "$TMP_DIR/diff.txt" >&2
  echo "" >&2
  echo "Run: bash scripts/gen-localizations.sh" >&2
  echo "then commit the regenerated files under Sources/Wink/Resources/Localized." >&2
  exit 1
fi

echo "Sources/Wink/Resources/Localized is up to date with $CATALOG"
