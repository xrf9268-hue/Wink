#!/usr/bin/env bash
# Release step one: sync version numbers (spec docs/superpowers/specs/2026-06-11-release-pipeline-hardening-design.md §4).
#   ./scripts/bump-version.sh X.Y.Z
# Writes Info.plist: CFBundleShortVersionString = X.Y.Z and CFBundleVersion += 1 (monotonic
# integer — Sparkle compares it as sparkle:version). Precondition: CHANGELOG.md already has a
# "## X.Y.Z" section; notes are creative content written by a human first, this script only gates.
set -euo pipefail

VER="${1:?usage: bump-version.sh X.Y.Z}"
if [[ ! "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Error: version must be three-part semver (X.Y.Z), got '$VER'" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INFO_PLIST="${INFO_PLIST:-$PROJECT_DIR/Sources/Wink/Resources/Info.plist}"
CHANGELOG="${CHANGELOG:-$PROJECT_DIR/CHANGELOG.md}"

CURRENT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
if [ "$VER" = "$CURRENT" ]; then
    echo "Error: version is already $CURRENT — nothing to bump" >&2
    exit 1
fi
if ! awk -v ver="$VER" '$1 == "##" && $2 == ver { found = 1 } END { exit !found }' "$CHANGELOG"; then
    echo "Error: CHANGELOG.md has no '## $VER' section — write the release notes first" >&2
    exit 1
fi
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
if [[ ! "$BUILD" =~ ^[0-9]+$ ]]; then
    echo "Error: CFBundleVersion '$BUILD' is not a non-negative integer — fix $INFO_PLIST first" >&2
    exit 1
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VER" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((BUILD + 1))" "$INFO_PLIST"
echo "Bumped $CURRENT -> $VER (CFBundleVersion $BUILD -> $((BUILD + 1)))"
echo "Next: swift test -> commit -> git tag v$VER -> git push origin main --tags"
