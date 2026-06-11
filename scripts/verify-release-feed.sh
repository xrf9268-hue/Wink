#!/usr/bin/env bash
# Release feed safety gate (spec docs/superpowers/specs/2026-06-11-release-pipeline-hardening-design.md §1).
# Restores the live Sparkle appcast to $SPARKLE_RESTORED_APPCAST and blocks any release whose
# CFBundleVersion would not move the feed strictly forward. --mode rehearse reports without enforcing.
# Only HTTP 404 *with* WINK_ALLOW_FIRST_RELEASE=1 may skip the comparison; fetch errors always fail.
set -euo pipefail

MODE="release"
while [ $# -gt 0 ]; do
    case "$1" in
        --mode)
            MODE="${2:?--mode requires release|rehearse}"
            shift 2
            ;;
        *)
            echo "Error: unknown argument '$1' (usage: verify-release-feed.sh [--mode release|rehearse])" >&2
            exit 64
            ;;
    esac
done
case "$MODE" in
    release|rehearse) ;;
    *)
        echo "Error: --mode must be release or rehearse, got '$MODE'" >&2
        exit 64
        ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INFO_PLIST="${INFO_PLIST:-$PROJECT_DIR/Sources/Wink/Resources/Info.plist}"
RESTORED_APPCAST="${SPARKLE_RESTORED_APPCAST:-$PROJECT_DIR/build/live-appcast.xml}"

if [ -z "${SPARKLE_PUBLIC_BASE_URL:-}" ]; then
    echo "Error: SPARKLE_PUBLIC_BASE_URL must point to the public update directory." >&2
    exit 1
fi
SPARKLE_PUBLIC_BASE_URL="$(printf '%s' "$SPARKLE_PUBLIC_BASE_URL" | sed 's#/*$#/#')"
FEED_URL="${SPARKLE_PUBLIC_BASE_URL}appcast.xml"

NEW_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
if ! printf '%s' "$NEW_BUILD" | grep -qE '^[0-9]+$'; then
    echo "Error: CFBundleVersion '$NEW_BUILD' is not a non-negative integer — fix $INFO_PLIST." >&2
    exit 1
fi

mkdir -p "$(dirname "$RESTORED_APPCAST")"
HTTP="$(curl -sSL --retry 3 --retry-all-errors -w '%{http_code}' -o "$RESTORED_APPCAST" "$FEED_URL" || echo 000)"
HTTP="${HTTP##*$'\n'}"

if [ "$HTTP" = "404" ]; then
    rm -f "$RESTORED_APPCAST"
    if [ "${WINK_ALLOW_FIRST_RELEASE:-}" = "1" ]; then
        echo "Live feed returned 404 and WINK_ALLOW_FIRST_RELEASE=1 — treating as first release."
        exit 0
    fi
    echo "Error: live feed $FEED_URL returned 404." >&2
    echo "If this is genuinely the first release, set WINK_ALLOW_FIRST_RELEASE=1; otherwise check SPARKLE_PUBLIC_BASE_URL." >&2
    exit 1
fi

if [ "$HTTP" != "200" ]; then
    rm -f "$RESTORED_APPCAST"
    echo "Error: fetching live feed $FEED_URL failed (HTTP $HTTP)." >&2
    echo "A fetch error must never be treated as a first release — re-run or investigate the feed host." >&2
    exit 1
fi

MAX_LIVE="$(
    {
        grep -oE '<sparkle:version>[0-9]+</sparkle:version>' "$RESTORED_APPCAST" || true
        grep -oE 'sparkle:version="[0-9]+"' "$RESTORED_APPCAST" || true
    } | grep -oE '[0-9]+' | sort -n | tail -1 || true
)"
if [ -z "$MAX_LIVE" ]; then
    echo "Error: restored feed $RESTORED_APPCAST has no parseable sparkle:version — feed corrupt?" >&2
    exit 1
fi

echo "Live feed max sparkle:version: $MAX_LIVE; this build's CFBundleVersion: $NEW_BUILD"

if [ "$MODE" = "rehearse" ]; then
    echo "Rehearse mode: version comparison reported, not enforced."
    exit 0
fi

if [ "$NEW_BUILD" -eq "$MAX_LIVE" ]; then
    echo "Error: CFBundleVersion $NEW_BUILD is already live — re-publishing a released version is not supported; bump a new version instead (scripts/bump-version.sh)." >&2
    exit 1
fi
if [ "$NEW_BUILD" -lt "$MAX_LIVE" ]; then
    echo "Error: CFBundleVersion $NEW_BUILD is lower than the live feed's $MAX_LIVE — forgot to run scripts/bump-version.sh?" >&2
    exit 1
fi

echo "Feed gate passed: $NEW_BUILD > $MAX_LIVE; restored live feed at $RESTORED_APPCAST"
