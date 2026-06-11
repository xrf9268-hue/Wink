#!/usr/bin/env bash
# Print the CHANGELOG.md body for one version (spec docs/superpowers/specs/2026-06-11-release-pipeline-hardening-design.md §5).
# release.yml calls this both as an early gate and to produce the GitHub Release body (--notes-file).
#   ./scripts/release-notes.sh X.Y.Z
set -euo pipefail

VER="${1:?usage: release-notes.sh X.Y.Z}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CHANGELOG="${CHANGELOG:-$PROJECT_DIR/CHANGELOG.md}"

if [ ! -f "$CHANGELOG" ]; then
    echo "Error: $CHANGELOG not found" >&2
    exit 1
fi

# Exact heading match ("## X.Y.Z"), body runs until the next "## " heading or EOF.
NOTES="$(awk -v ver="$VER" '
    $1 == "##" && $2 == ver { found = 1; next }
    $1 == "##" { if (found) exit }
    found { print }
' "$CHANGELOG")"

if ! printf '%s' "$NOTES" | grep -q '[^[:space:]]'; then
    echo "Error: CHANGELOG.md has no non-empty '## $VER' section — write the release notes first" >&2
    exit 1
fi
printf '%s\n' "$NOTES"
