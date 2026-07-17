#!/usr/bin/env bash
# Runtime acceptance for issue #317's incremental Carbon reconciliation.
#
# This script never changes TCC. It builds a signed Carbon binding-fault bundle,
# launches that bundle through LaunchServices with automatic permission prompts
# suppressed, and requires Accessibility to have been granted beforehand.
#
# Environment:
#   BASE_SHA=<recorded-40-character-base-sha>  # required
#   EVIDENCE_DIR=/absolute/path/to/new-or-empty-evidence-directory
#   EXPECTED_HEAD=<40-character-commit-sha>
#   POLL_TIMEOUT_SECONDS=30
#   PHYSICAL_TIMEOUT_SECONDS=180
#   WAIT_FOR_PHYSICAL=1  # set to 0 for the non-physical metrics gate only
set -euo pipefail
umask 077
shopt -s nullglob

APP_NAME="Wink"
BUNDLE_ID="com.wink.app"
EXPECTED_PROFILE="carbon-binding-fault-injection"
FAULT_ARGUMENT="--validation-carbon-binding-fault=permanent-conflict:38:6400"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
FIXTURE_PATH="$SCRIPT_DIR/fixtures/issue-317-20-standard.json"
SHORTCUTS_FILE="$HOME/Library/Application Support/Wink/shortcuts.json"
USAGE_DB_FILE="$HOME/Library/Application Support/Wink/usage.db"
LOG_FILE="$HOME/.config/Wink/debug.log"

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

assert_no_wink_processes() {
    local existing_wink_pids
    existing_wink_pids="$(pgrep -x "$APP_NAME" || true)"
    [ -z "$existing_wink_pids" ] \
        || die "stop every existing Wink process before validation (pids: ${existing_wink_pids//$'\n'/,})"
}

for command_name in codesign defaults ditto git jq open plutil pgrep ps python3 shasum tee; do
    require_command "$command_name"
done
[ "$(uname -s)" = "Darwin" ] || die "this runtime acceptance must run on macOS"

EXPECTED_HEAD="${EXPECTED_HEAD:-$(git -C "$PROJECT_DIR" rev-parse HEAD)}"
[[ "$EXPECTED_HEAD" =~ ^[0-9a-f]{40}$ ]] \
    || die "EXPECTED_HEAD must be one lowercase 40-character SHA: $EXPECTED_HEAD"
BASE_SHA="${BASE_SHA:-}"
[[ "$BASE_SHA" =~ ^[0-9a-f]{40}$ ]] \
    || die "BASE_SHA must be the recorded lowercase 40-character issue base"
CURRENT_HEAD="$(git -C "$PROJECT_DIR" rev-parse HEAD)"
[ "$CURRENT_HEAD" = "$EXPECTED_HEAD" ] \
    || die "current HEAD $CURRENT_HEAD does not match EXPECTED_HEAD $EXPECTED_HEAD"
RESOLVED_EXPECTED_HEAD="$(git -C "$PROJECT_DIR" rev-parse --verify "$EXPECTED_HEAD^{commit}")"
[ "$RESOLVED_EXPECTED_HEAD" = "$EXPECTED_HEAD" ] \
    || die "EXPECTED_HEAD does not resolve to the exact current commit"
RESOLVED_BASE_SHA="$(git -C "$PROJECT_DIR" rev-parse --verify "$BASE_SHA^{commit}")"
[ "$RESOLVED_BASE_SHA" = "$BASE_SHA" ] \
    || die "BASE_SHA does not resolve to the exact recorded commit"
git -C "$PROJECT_DIR" merge-base --is-ancestor "$BASE_SHA" "$EXPECTED_HEAD" \
    || die "BASE_SHA is not an ancestor of EXPECTED_HEAD"

GIT_STATUS="$(git -C "$PROJECT_DIR" status --porcelain --untracked-files=all)"
[ -z "$GIT_STATUS" ] || {
    printf '%s\n' "$GIT_STATUS" >&2
    die "worktree must be clean so evidence is bound to one exact source state"
}

LOCK_DIR="${TMPDIR:-/tmp}/wink-issue-317-${UID}.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    die "another issue #317 validation owns $LOCK_DIR; remove it only after confirming no validation is running"
fi
printf '%s\n' "$$" >"$LOCK_DIR/pid"
early_cleanup() {
    rm -f "$LOCK_DIR/pid"
    rmdir "$LOCK_DIR" 2>/dev/null || true
}
trap early_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

assert_no_wink_processes

EVIDENCE_DIR="${EVIDENCE_DIR:-$PROJECT_DIR/build/validation/issue-317-$EXPECTED_HEAD/carbon-binding-retry}"
if [[ "$EVIDENCE_DIR" != /* ]]; then
    EVIDENCE_DIR="$PROJECT_DIR/$EVIDENCE_DIR"
fi
if [ -d "$EVIDENCE_DIR" ] && [ -n "$(find "$EVIDENCE_DIR" -mindepth 1 -print -quit)" ]; then
    die "EVIDENCE_DIR must be new or empty: $EVIDENCE_DIR"
fi
mkdir -p "$EVIDENCE_DIR"
EVIDENCE_PARENT="$(cd "$(dirname "$EVIDENCE_DIR")" && pwd -P)"
EVIDENCE_DIR="$EVIDENCE_PARENT/$(basename "$EVIDENCE_DIR")"

# Build inside this clean, exact-head process so a caller cannot accidentally
# attribute a stale injected bundle to EXPECTED_HEAD. Preserve the resulting
# bundle before the later clean production rebuild replaces build/Wink.app.
BUILT_APP_PATH="$PROJECT_DIR/build/Wink.app"
PACKAGE_OUTPUT="$EVIDENCE_DIR/package-injected.txt"
printf 'WINK_VALIDATION_CARBON_BINDING_FAULT_INJECTION=1 WINK_VALIDATION_SOURCE_REVISION=%q bash %q\n' \
    "$EXPECTED_HEAD" "$PROJECT_DIR/scripts/package-app.sh" >"$EVIDENCE_DIR/package-command.txt"
WINK_VALIDATION_CARBON_BINDING_FAULT_INJECTION=1 \
    WINK_VALIDATION_SOURCE_REVISION="$EXPECTED_HEAD" \
    bash "$PROJECT_DIR/scripts/package-app.sh" 2>&1 | tee "$PACKAGE_OUTPUT"
[ "$(git -C "$PROJECT_DIR" rev-parse HEAD)" = "$EXPECTED_HEAD" ] \
    || die "HEAD changed while the injected bundle was building"
POST_BUILD_STATUS="$(git -C "$PROJECT_DIR" status --porcelain --untracked-files=all)"
[ -z "$POST_BUILD_STATUS" ] || {
    printf '%s\n' "$POST_BUILD_STATUS" >&2
    die "source worktree changed while the injected bundle was building"
}
[ -d "$BUILT_APP_PATH" ] || die "package script did not create $BUILT_APP_PATH"
assert_no_wink_processes
mkdir -p "$EVIDENCE_DIR/bundles"
PRESERVED_APP_PATH="$EVIDENCE_DIR/bundles/injected-Wink.app"
ditto "$BUILT_APP_PATH" "$PRESERVED_APP_PATH"
APP_PATH="$BUILT_APP_PATH"

INFO_PLIST="$APP_PATH/Contents/Info.plist"
EXECUTABLE="$APP_PATH/Contents/MacOS/$APP_NAME"
[ -f "$INFO_PLIST" ] || die "Info.plist not found: $INFO_PLIST"
[ -x "$EXECUTABLE" ] || die "packaged executable not found or not executable: $EXECUTABLE"

ACTUAL_BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$INFO_PLIST")"
[ "$ACTUAL_BUNDLE_ID" = "$BUNDLE_ID" ] \
    || die "unexpected bundle identifier: $ACTUAL_BUNDLE_ID"
ACTUAL_EXECUTABLE="$(plutil -extract CFBundleExecutable raw -o - "$INFO_PLIST")"
[ "$ACTUAL_EXECUTABLE" = "$APP_NAME" ] \
    || die "unexpected CFBundleExecutable: $ACTUAL_EXECUTABLE"
ACTUAL_PROFILE="$(plutil -extract WinkRuntimeValidationProfile raw -o - "$INFO_PLIST" 2>/dev/null || true)"
[ "$ACTUAL_PROFILE" = "$EXPECTED_PROFILE" ] \
    || die "expected validation profile '$EXPECTED_PROFILE', got '${ACTUAL_PROFILE:-missing}'"
ACTUAL_SOURCE_REVISION="$(plutil -extract WinkRuntimeValidationSourceRevision raw -o - "$INFO_PLIST" 2>/dev/null || true)"
[ "$ACTUAL_SOURCE_REVISION" = "$EXPECTED_HEAD" ] \
    || die "injected bundle source revision '${ACTUAL_SOURCE_REVISION:-missing}' does not match $EXPECTED_HEAD"

[ -f "$FIXTURE_PATH" ] || die "fixture not found: $FIXTURE_PATH"
jq -e '
    type == "array"
    and length == 20
    and ([.[].id] | unique | length) == 20
    and ([.[].keyEquivalent] == [
        "a", "b", "c", "d", "e", "f", "g", "h", "i", "j",
        "k", "l", "m", "n", "o", "p", "q", "r", "s", "t"
    ])
    and all(.[];
        .isEnabled == true
        and (.bundleIdentifier == "com.apple.Safari" or .bundleIdentifier == "com.apple.Notes")
        and .modifierFlags == ["command", "option", "control"]
    )
    and (.[0] | .appName == "Notes" and .bundleIdentifier == "com.apple.Notes" and .keyEquivalent == "a")
    and (map(select(.bundleIdentifier == "com.apple.Notes")) | length == 1)
    and (map(select(.keyEquivalent == "j")) | length == 1)
' "$FIXTURE_PATH" >/dev/null || die "issue #317 fixture does not match the required 20-binding standard matrix"

[ -d /System/Applications/Safari.app ] || die "Safari.app is unavailable"
[ -d /System/Applications/Notes.app ] || die "Notes.app is unavailable"

POLL_TIMEOUT_SECONDS="${POLL_TIMEOUT_SECONDS:-30}"
PHYSICAL_TIMEOUT_SECONDS="${PHYSICAL_TIMEOUT_SECONDS:-180}"
WAIT_FOR_PHYSICAL="${WAIT_FOR_PHYSICAL:-1}"
[[ "$POLL_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "POLL_TIMEOUT_SECONDS must be a positive integer"
[[ "$PHYSICAL_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "PHYSICAL_TIMEOUT_SECONDS must be a positive integer"
case "$WAIT_FOR_PHYSICAL" in
    0|1) ;;
    *) die "WAIT_FOR_PHYSICAL must be 0 or 1" ;;
esac

[ ! -L "$SHORTCUTS_FILE" ] || die "refusing to replace symlinked shortcuts file: $SHORTCUTS_FILE"
[ ! -L "$LOG_FILE" ] || die "refusing to replace symlinked diagnostic log: $LOG_FILE"
if ORIGINAL_HYPER_VALUE="$(defaults read "$BUNDLE_ID" hyperKeyEnabled 2>/dev/null)"; then
    HYPER_KEY_EXISTED=1
    case "$ORIGINAL_HYPER_VALUE" in
        0|1) ;;
        *) die "hyperKeyEnabled is not a Boolean-compatible value: $ORIGINAL_HYPER_VALUE" ;;
    esac
else
    HYPER_KEY_EXISTED=0
    ORIGINAL_HYPER_VALUE=""
fi

if SHORTCUTS_PAUSED="$(defaults read "$BUNDLE_ID" shortcutsPaused 2>/dev/null)"; then
    case "$SHORTCUTS_PAUSED" in
        0) ;;
        1) die "shortcuts are paused; unpause Wink before running this acceptance" ;;
        *) die "shortcutsPaused is not a Boolean-compatible value: $SHORTCUTS_PAUSED" ;;
    esac
fi

if ! codesign --verify --deep --strict --verbose=2 "$APP_PATH" \
    >"$EVIDENCE_DIR/codesign-verification.txt" 2>&1; then
    sed -n '1,160p' "$EVIDENCE_DIR/codesign-verification.txt" >&2
    die "codesign verification failed for $APP_PATH"
fi
codesign -dv --verbose=4 "$APP_PATH" >"$EVIDENCE_DIR/codesign-details.txt" 2>&1
if ! codesign --verify --deep --strict --verbose=2 "$PRESERVED_APP_PATH" \
    >"$EVIDENCE_DIR/codesign-preserved-verification.txt" 2>&1; then
    sed -n '1,160p' "$EVIDENCE_DIR/codesign-preserved-verification.txt" >&2
    die "codesign verification failed for preserved bundle $PRESERVED_APP_PATH"
fi

EXECUTABLE_SHA256="$(shasum -a 256 "$EXECUTABLE" | awk '{print $1}')"
PRESERVED_EXECUTABLE="$PRESERVED_APP_PATH/Contents/MacOS/$APP_NAME"
PRESERVED_EXECUTABLE_SHA256="$(shasum -a 256 "$PRESERVED_EXECUTABLE" | awk '{print $1}')"
FIXTURE_SHA256="$(shasum -a 256 "$FIXTURE_PATH" | awk '{print $1}')"
[[ "$EXECUTABLE_SHA256" =~ ^[0-9a-f]{64}$ ]] || die "failed to calculate executable SHA-256"
[[ "$PRESERVED_EXECUTABLE_SHA256" =~ ^[0-9a-f]{64}$ ]] || die "failed to calculate preserved executable SHA-256"
[ "$EXECUTABLE_SHA256" = "$PRESERVED_EXECUTABLE_SHA256" ] \
    || die "preserved executable differs from the exact bundle built in this process"
[[ "$FIXTURE_SHA256" =~ ^[0-9a-f]{64}$ ]] || die "failed to calculate fixture SHA-256"

printf '%s\n' "$EXPECTED_HEAD" >"$EVIDENCE_DIR/head.txt"
printf '%s\n' "$BASE_SHA" >"$EVIDENCE_DIR/base.txt"
printf '%s\n' "$BUILT_APP_PATH" >"$EVIDENCE_DIR/built-app-path.txt"
printf '%s\n' "$PRESERVED_APP_PATH" >"$EVIDENCE_DIR/preserved-app-path.txt"
printf '%s\n' "$APP_PATH" >"$EVIDENCE_DIR/app-path.txt"
printf '%s\n' "$EXECUTABLE" >"$EVIDENCE_DIR/executable-path.txt"
printf '%s  %s\n' "$EXECUTABLE_SHA256" "$EXECUTABLE" >"$EVIDENCE_DIR/executable-sha256.txt"
printf '%s  %s\n' "$FIXTURE_SHA256" "$FIXTURE_PATH" >"$EVIDENCE_DIR/fixture-sha256.txt"
plutil -p "$INFO_PLIST" >"$EVIDENCE_DIR/info-plist.txt"
git -C "$PROJECT_DIR" status --porcelain --untracked-files=all >"$EVIDENCE_DIR/git-status.txt"
{
    sw_vers
    uname -m
} >"$EVIDENCE_DIR/host.txt"
{
    printf 'base=%s\n' "$BASE_SHA"
    printf 'head=%s\n' "$EXPECTED_HEAD"
    printf 'builtAppPath=%s\n' "$BUILT_APP_PATH"
    printf 'preservedAppPath=%s\n' "$PRESERVED_APP_PATH"
    printf 'appPath=%s\n' "$APP_PATH"
    printf 'executablePath=%s\n' "$EXECUTABLE"
    printf 'executableSHA256=%s\n' "$EXECUTABLE_SHA256"
    printf 'fixturePath=%s\n' "$FIXTURE_PATH"
    printf 'fixtureSHA256=%s\n' "$FIXTURE_SHA256"
    printf 'profile=%s\n' "$ACTUAL_PROFILE"
    printf 'sourceRevision=%s\n' "$ACTUAL_SOURCE_REVISION"
    printf 'faultArgument=%s\n' "$FAULT_ARGUMENT"
    printf 'retryPolicy=one failed-binding attempt per three-second permission poll\n'
} >"$EVIDENCE_DIR/identity.txt"

SHORTCUTS_EXISTED=0
LOG_EXISTED=0
DEFAULTS_DOMAIN_EXISTED=0
SHORTCUTS_ORIGINAL_SHA256="absent"
LOG_ORIGINAL_SHA256="absent"
APP_PID=""
STATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wink-issue-317.XXXXXX")"
mkdir -p "$STATE_DIR/usage-db"
: >"$STATE_DIR/usage-db-manifest.txt"

if [ -f "$SHORTCUTS_FILE" ]; then
    SHORTCUTS_EXISTED=1
    cp -p "$SHORTCUTS_FILE" "$STATE_DIR/shortcuts.json"
    SHORTCUTS_ORIGINAL_SHA256="$(shasum -a 256 "$SHORTCUTS_FILE" | awk '{print $1}')"
fi
if [ -f "$LOG_FILE" ]; then
    LOG_EXISTED=1
    cp -p "$LOG_FILE" "$STATE_DIR/debug.log"
    LOG_ORIGINAL_SHA256="$(shasum -a 256 "$LOG_FILE" | awk '{print $1}')"
fi
if defaults export "$BUNDLE_ID" "$STATE_DIR/defaults.plist" >/dev/null 2>&1; then
    DEFAULTS_DOMAIN_EXISTED=1
fi
ORIGINAL_USAGE_PATHS=("$USAGE_DB_FILE"*)
for usage_path in "${ORIGINAL_USAGE_PATHS[@]}"; do
    [ ! -L "$usage_path" ] || die "refusing to replace symlinked usage state: $usage_path"
    [ -f "$usage_path" ] || die "unexpected non-file usage state: $usage_path"
    usage_name="$(basename "$usage_path")"
    cp -p "$usage_path" "$STATE_DIR/usage-db/$usage_name"
    printf '%s\t%s\n' \
        "$usage_name" \
        "$(shasum -a 256 "$usage_path" | awk '{print $1}')" \
        >>"$STATE_DIR/usage-db-manifest.txt"
done
cp "$STATE_DIR/usage-db-manifest.txt" "$EVIDENCE_DIR/usage-db-original-manifest.txt"

# Packaging can take long enough for a user or another process to relaunch
# Wink. Refuse to touch shared state unless it is still quiescent now.
assert_no_wink_processes

cleanup() {
    local status=$?
    local restore_failed=0
    trap - EXIT
    trap '' INT TERM
    set +e

    if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
        local running_command
        running_command="$(ps -p "$APP_PID" -o command= 2>/dev/null)"
        if [[ "$running_command" == "$EXECUTABLE"* ]]; then
            kill -TERM "$APP_PID" 2>/dev/null
            local attempt=0
            while kill -0 "$APP_PID" 2>/dev/null && [ "$attempt" -lt 10 ]; do
                sleep 1
                attempt=$((attempt + 1))
            done
            if kill -0 "$APP_PID" 2>/dev/null; then
                kill -KILL "$APP_PID" 2>/dev/null
            fi
            wait "$APP_PID" 2>/dev/null
        else
            printf 'WARNING: refusing to terminate pid %s because its command changed: %s\n' \
                "$APP_PID" "$running_command" >&2
            restore_failed=1
        fi
    fi

    mkdir -p "$(dirname "$SHORTCUTS_FILE")" || restore_failed=1
    if [ "$SHORTCUTS_EXISTED" -eq 1 ]; then
        if ! cp -p "$STATE_DIR/shortcuts.json" "$SHORTCUTS_FILE.restore.$$" \
            || ! mv -f "$SHORTCUTS_FILE.restore.$$" "$SHORTCUTS_FILE"; then
            printf 'WARNING: failed to restore %s\n' "$SHORTCUTS_FILE" >&2
            restore_failed=1
        elif [ "$(shasum -a 256 "$SHORTCUTS_FILE" | awk '{print $1}')" != "$SHORTCUTS_ORIGINAL_SHA256" ]; then
            printf 'WARNING: restored shortcuts checksum does not match the backup\n' >&2
            restore_failed=1
        fi
    else
        rm -f "$SHORTCUTS_FILE" || restore_failed=1
        [ ! -e "$SHORTCUTS_FILE" ] || restore_failed=1
    fi

    mkdir -p "$(dirname "$LOG_FILE")" || restore_failed=1
    if [ "$LOG_EXISTED" -eq 1 ]; then
        if ! cp -p "$STATE_DIR/debug.log" "$LOG_FILE.restore.$$" \
            || ! mv -f "$LOG_FILE.restore.$$" "$LOG_FILE"; then
            printf 'WARNING: failed to restore %s\n' "$LOG_FILE" >&2
            restore_failed=1
        elif [ "$(shasum -a 256 "$LOG_FILE" | awk '{print $1}')" != "$LOG_ORIGINAL_SHA256" ]; then
            printf 'WARNING: restored diagnostic-log checksum does not match the backup\n' >&2
            restore_failed=1
        fi
    else
        rm -f "$LOG_FILE" || restore_failed=1
        [ ! -e "$LOG_FILE" ] || restore_failed=1
    fi

    defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
    if [ "$DEFAULTS_DOMAIN_EXISTED" -eq 1 ]; then
        if ! defaults import "$BUNDLE_ID" "$STATE_DIR/defaults.plist" >/dev/null 2>&1 \
            || ! defaults export "$BUNDLE_ID" "$STATE_DIR/defaults-restored.plist" >/dev/null 2>&1 \
            || ! python3 - "$STATE_DIR/defaults.plist" "$STATE_DIR/defaults-restored.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as expected_file:
    expected = plistlib.load(expected_file)
with open(sys.argv[2], "rb") as actual_file:
    actual = plistlib.load(actual_file)
raise SystemExit(0 if actual == expected else 1)
PY
        then
            printf 'WARNING: failed to restore the com.wink.app defaults domain exactly\n' >&2
            restore_failed=1
        fi
    else
        if defaults read "$BUNDLE_ID" >/dev/null 2>&1; then
            printf 'WARNING: failed to restore the absent com.wink.app defaults domain\n' >&2
            restore_failed=1
        fi
    fi

    current_usage_paths=("$USAGE_DB_FILE"*)
    if [ "${#current_usage_paths[@]}" -gt 0 ]; then
        rm -f -- "${current_usage_paths[@]}" || restore_failed=1
    fi
    mkdir -p "$(dirname "$USAGE_DB_FILE")" || restore_failed=1
    saved_usage_paths=("$STATE_DIR/usage-db/"*)
    for saved_usage_path in "${saved_usage_paths[@]}"; do
        cp -p "$saved_usage_path" "$(dirname "$USAGE_DB_FILE")/$(basename "$saved_usage_path")" \
            || restore_failed=1
    done
    restored_usage_paths=("$USAGE_DB_FILE"*)
    if [ "${#restored_usage_paths[@]}" -ne "$(wc -l <"$STATE_DIR/usage-db-manifest.txt" | tr -d ' ')" ]; then
        printf 'WARNING: restored usage database file count does not match the backup\n' >&2
        restore_failed=1
    fi
    while IFS=$'\t' read -r usage_name expected_usage_sha; do
        [ -n "$usage_name" ] || continue
        restored_usage_path="$(dirname "$USAGE_DB_FILE")/$usage_name"
        if [ ! -f "$restored_usage_path" ] \
            || [ "$(shasum -a 256 "$restored_usage_path" | awk '{print $1}')" != "$expected_usage_sha" ]; then
            printf 'WARNING: restored usage state does not match backup: %s\n' "$usage_name" >&2
            restore_failed=1
        fi
    done <"$STATE_DIR/usage-db-manifest.txt"

    {
        printf 'shortcutsOriginalSHA256=%s\n' "$SHORTCUTS_ORIGINAL_SHA256"
        printf 'debugLogOriginalSHA256=%s\n' "$LOG_ORIGINAL_SHA256"
        printf 'hyperKeyOriginallyPresent=%s\n' "$HYPER_KEY_EXISTED"
        printf 'hyperKeyOriginalValue=%s\n' "${ORIGINAL_HYPER_VALUE:-absent}"
        printf 'defaultsDomainOriginallyPresent=%s\n' "$DEFAULTS_DOMAIN_EXISTED"
        printf 'usageDatabaseFilesOriginallyPresent=%s\n' "$(wc -l <"$STATE_DIR/usage-db-manifest.txt" | tr -d ' ')"
        printf 'restored=%s\n' "$([ "$restore_failed" -eq 0 ] && printf true || printf false)"
    } >"$EVIDENCE_DIR/restoration.txt"

    rm -rf "$STATE_DIR" || restore_failed=1
    rm -f "$LOCK_DIR/pid" || restore_failed=1
    rmdir "$LOCK_DIR" || restore_failed=1
    if [ "$restore_failed" -ne 0 ]; then
        status=1
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$(dirname "$SHORTCUTS_FILE")" "$(dirname "$LOG_FILE")"
install -m 600 "$FIXTURE_PATH" "$SHORTCUTS_FILE"
defaults write "$BUNDLE_ID" hyperKeyEnabled -bool false
[ "$(defaults read "$BUNDLE_ID" hyperKeyEnabled)" = "0" ] \
    || die "failed to disable Hyper routing for the isolated standard fixture"
rm -f "$LOG_FILE"
touch "$LOG_FILE"

LAUNCH_OUTPUT="$EVIDENCE_DIR/launchservices-output.txt"
printf 'open -n -a %q --args %q %q\n' \
    "$APP_PATH" \
    "--suppress-automatic-permission-prompts" \
    "$FAULT_ARGUMENT" \
    >"$EVIDENCE_DIR/launch-command.txt"
open -n -a "$APP_PATH" --args \
    --suppress-automatic-permission-prompts \
    "$FAULT_ARGUMENT" \
    >"$LAUNCH_OUTPUT" 2>&1

elapsed=0
while [ "$elapsed" -lt 10 ] && [ -z "$APP_PID" ]; do
    for candidate_pid in $(pgrep -x "$APP_NAME" || true); do
        candidate_command="$(ps -p "$candidate_pid" -o command= 2>/dev/null)"
        if [[ "$candidate_command" == "$EXECUTABLE"* ]]; then
            [ -z "$APP_PID" ] \
                || die "multiple instances of the exact injected bundle are running"
            APP_PID="$candidate_pid"
        fi
    done
    [ -n "$APP_PID" ] && break
    sleep 1
    elapsed=$((elapsed + 1))
done
[ -n "$APP_PID" ] || die "LaunchServices did not start the exact packaged app; inspect $LAUNCH_OUTPUT"
printf '%s\n' "$APP_PID" >"$EVIDENCE_DIR/app-pid.txt"
kill -0 "$APP_PID" 2>/dev/null || die "exact packaged app exited during startup; inspect $LAUNCH_OUTPUT"
RUNNING_COMMAND="$(ps -p "$APP_PID" -o command= 2>/dev/null)"
[[ "$RUNNING_COMMAND" == "$EXECUTABLE"* ]] \
    || die "launched pid $APP_PID is not the exact requested executable: $RUNNING_COMMAND"
printf '%s\n' "$RUNNING_COMMAND" >"$EVIDENCE_DIR/running-command.txt"

elapsed=0
while [ "$elapsed" -lt "$POLL_TIMEOUT_SECONDS" ]; do
    kill -0 "$APP_PID" 2>/dev/null \
        || die "exact packaged app exited while waiting for permission polls; inspect $LAUNCH_OUTPUT"
    poll_count="$(grep -c 'checkPermission:' "$LOG_FILE" 2>/dev/null || true)"
    sync_count="$(grep -c 'CARBON_HOTKEY_SYNC ' "$LOG_FILE" 2>/dev/null || true)"
    if [ "$poll_count" -ge 5 ] && [ "$sync_count" -ge $((poll_count + 1)) ]; then
        break
    fi
    sleep 1
    elapsed=$((elapsed + 1))
done

poll_count="$(grep -c 'checkPermission:' "$LOG_FILE" 2>/dev/null || true)"
sync_count="$(grep -c 'CARBON_HOTKEY_SYNC ' "$LOG_FILE" 2>/dev/null || true)"
[ "$poll_count" -ge 5 ] \
    || die "timed out with only $poll_count real permission polls (need at least 5)"
[ "$sync_count" -ge $((poll_count + 1)) ] \
    || die "timed out before the retry for poll $poll_count was logged"

# Freeze at the first completed sync after the fifth permission poll. Selecting
# an immutable line-number prefix avoids racing the still-live three-second
# timer if it begins a sixth poll while evidence is being copied. Retain only
# the readiness/counter families required by this acceptance.
SNAPSHOT_CUTOFF_LINE="$(awk '
    /checkPermission:/ { poll_count += 1 }
    /CARBON_HOTKEY_SYNC / && poll_count >= 5 { print NR; exit }
' "$LOG_FILE")"
[[ "$SNAPSHOT_CUTOFF_LINE" =~ ^[1-9][0-9]*$ ]] \
    || die "could not locate the completed synchronization after permission poll five"
awk -v cutoff="$SNAPSHOT_CUTOFF_LINE" '
    NR > cutoff { exit }
    /CARBON_HOTKEY_SYNC / \
        || /checkPermission:/ \
        || /CARBON_BINDING_FAULT_INJECTION / \
        || /SHORTCUT_TRACE_BLOCKED / { print }
' "$LOG_FILE" >"$EVIDENCE_DIR/runtime-readiness-sanitized.log"

python3 - "$EVIDENCE_DIR/runtime-readiness-sanitized.log" "$EVIDENCE_DIR/runtime-summary.json" <<'PY'
import datetime
import json
import pathlib
import sys

log_path = pathlib.Path(sys.argv[1])
summary_path = pathlib.Path(sys.argv[2])
lines = log_path.read_text(encoding="utf-8").splitlines()


def fail(message):
    raise SystemExit(f"runtime assertion failed: {message}")


def fields(line):
    parsed = {}
    for token in line.split():
        if "=" in token:
            key, value = token.split("=", 1)
            parsed[key] = value
    return parsed


def require_fields(actual, expected, label):
    for key, value in expected.items():
        observed = actual.get(key)
        if observed != str(value):
            fail(f"{label}: expected {key}={value}, got {observed}")


sync_lines = [line for line in lines if "CARBON_HOTKEY_SYNC " in line]
poll_lines = [line for line in lines if "checkPermission:" in line]
fault_lines = [line for line in lines if "CARBON_BINDING_FAULT_INJECTION " in line]

if len(poll_lines) < 5:
    fail(f"expected at least 5 checkPermission polls, got {len(poll_lines)}")
if len(sync_lines) != len(poll_lines) + 1:
    fail(
        "expected exactly one initial sync plus one sync per poll, "
        f"got syncs={len(sync_lines)} polls={len(poll_lines)}"
    )

initial = fields(sync_lines[0])
require_fields(
    initial,
    {
        "sequence": 1,
        "handlerState": "installed",
        "desired": 20,
        "retained": 0,
        "lowLevelAttempts": 20,
        "lowLevelSuccesses": 19,
        "lowLevelUnregisters": 0,
        "active": 19,
        "failures": 1,
        "rolledBack": 0,
    },
    "initial sync",
)

retry_expected = {
    "handlerState": "installed",
    "desired": 20,
    "retained": 19,
    "lowLevelAttempts": 1,
    "lowLevelSuccesses": 0,
    "lowLevelUnregisters": 0,
    "active": 19,
    "failures": 1,
    "rolledBack": 0,
}
for index, line in enumerate(sync_lines[1:], start=2):
    parsed = fields(line)
    require_fields(parsed, {"sequence": index, **retry_expected}, f"retry sync {index - 1}")

for index, line in enumerate(poll_lines, start=1):
    require_fields(
        fields(line),
        {"ax": "true", "carbon": "false", "eventTap": "false"},
        f"permission poll {index}",
    )

first_poll_time = datetime.datetime.fromisoformat(poll_lines[0].split()[0].replace("Z", "+00:00"))
fifth_poll_time = datetime.datetime.fromisoformat(poll_lines[4].split()[0].replace("Z", "+00:00"))
poll_span_seconds = int((fifth_poll_time - first_poll_time).total_seconds())
if poll_span_seconds < 11:
    fail(f"first five polls span only {poll_span_seconds}s; expected timer-driven 3s intervals")

if not fault_lines:
    fail("fault-injection diagnostics are absent")
final_fault = fields(fault_lines[-1])
expected_register_calls = 20 + len(poll_lines)
expected_injected_failures = 1 + len(poll_lines)
require_fields(
    final_fault,
    {
        "mode": "permanent-conflict",
        "targetKeyCode": 38,
        "targetModifiers": 6400,
        "registerCalls": expected_register_calls,
        "forwardedRegisterCalls": 19,
        "injectedFailures": expected_injected_failures,
        "unregisterCalls": 0,
    },
    "final fault counters",
)
if expected_register_calls < 25 or expected_injected_failures < 6:
    fail("fault counter lower bounds were not reached")

if not any(
    "event=register_injected" in line
    and "keyCode=38" in line
    and "modifiers=6400" in line
    and "status=-9878" in line
    for line in fault_lines
):
    fail("the exact J/6400 conflict was not observed")

if not any(
    "SHORTCUT_TRACE_BLOCKED " in line
    and 'reason="missing_registration_or_system_conflict"' in line
    and "standardShortcutCount=20" in line
    and "registeredStandardShortcutCount=19" in line
    for line in lines
):
    fail("truthful partial-readiness diagnostic (19/20, carbon=false) is absent")

summary = {
    "retryPolicy": "one failed-binding attempt per three-second permission poll",
    "permissionPollIntervalSeconds": 3,
    "pollCount": len(poll_lines),
    "pollSpanFirstToFifthSeconds": poll_span_seconds,
    "syncCount": len(sync_lines),
    "initialSync": initial,
    "retrySyncCount": len(sync_lines) - 1,
    "finalFaultCounters": {
        key: final_fault[key]
        for key in (
            "registerCalls",
            "forwardedRegisterCalls",
            "injectedFailures",
            "unregisterCalls",
        )
    },
    "readiness": "partial-standard-carbon-false",
}
summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(
    "PASS: "
    f"polls={len(poll_lines)} syncs={len(sync_lines)} "
    f"registerCalls={final_fault['registerCalls']} "
    f"forwardedRegisterCalls={final_fault['forwardedRegisterCalls']} "
    f"injectedFailures={final_fault['injectedFailures']} "
    f"unregisterCalls={final_fault['unregisterCalls']}"
)
PY

jq -e '
    .retryPolicy == "one failed-binding attempt per three-second permission poll"
    and .permissionPollIntervalSeconds == 3
    and .pollCount >= 5
    and .syncCount == (.pollCount + 1)
    and .retrySyncCount == .pollCount
    and (.finalFaultCounters.forwardedRegisterCalls | tonumber) == 19
    and (.finalFaultCounters.unregisterCalls | tonumber) == 0
' "$EVIDENCE_DIR/runtime-summary.json" >/dev/null \
    || die "runtime summary failed its independent jq integrity check"

if [ "$WAIT_FOR_PHYSICAL" -eq 0 ]; then
    printf 'Physical observation skipped because WAIT_FOR_PHYSICAL=0.\n' \
        >"$EVIDENCE_DIR/physical-input-skipped.txt"
    printf 'PASS_METRICS_ONLY_PHYSICAL_PENDING evidence=%s head=%s executableSHA256=%s\n' \
        "$EVIDENCE_DIR" "$EXPECTED_HEAD" "$EXECUTABLE_SHA256"
    exit 2
fi

PHYSICAL_PRE_LINES="$(wc -l <"$LOG_FILE" | tr -d ' ')"
touch "$EVIDENCE_DIR/READY_FOR_PHYSICAL_CTRL_ALT_COMMAND_A"
printf 'READY_FOR_PHYSICAL_CTRL_ALT_COMMAND_A\n'
printf 'Press physical Ctrl+Alt+Command+A now (Windows keyboard: Ctrl+Alt+Win+A).\n'
elapsed=0
while [ "$elapsed" -lt "$PHYSICAL_TIMEOUT_SECONDS" ]; do
    kill -0 "$APP_PID" 2>/dev/null \
        || die "exact packaged app exited while waiting for the physical key"
    physical_slice="$(tail -n +"$((PHYSICAL_PRE_LINES + 1))" "$LOG_FILE" 2>/dev/null || true)"
    if grep -Fq 'MATCHED: Notes - com.apple.Notes' <<<"$physical_slice" \
        && grep -Fq 'SHORTCUT_TRACE_DECISION event=matched bundle=com.apple.Notes route=standard' <<<"$physical_slice"; then
        grep -E 'MATCHED: Notes - com\.apple\.Notes|SHORTCUT_TRACE_DECISION event=matched bundle=com\.apple\.Notes route=standard' \
            <<<"$physical_slice" >"$EVIDENCE_DIR/physical-input-observation-sanitized.log"
        printf 'OBSERVED_PHYSICAL_STANDARD_MATCH_CTRL_ALT_COMMAND_A\n' \
            | tee "$EVIDENCE_DIR/physical-input-observed.txt"
        break
    fi
    sleep 1
    elapsed=$((elapsed + 1))
done
if [ ! -f "$EVIDENCE_DIR/physical-input-observed.txt" ]; then
    tail -n +"$((PHYSICAL_PRE_LINES + 1))" "$LOG_FILE" 2>/dev/null \
        | grep -E 'MATCHED: Notes - com\.apple\.Notes|SHORTCUT_TRACE_DECISION event=matched bundle=com\.apple\.Notes route=standard' \
        >"$EVIDENCE_DIR/physical-input-timeout-sanitized.log" || true
fi
[ -f "$EVIDENCE_DIR/physical-input-observed.txt" ] \
    || die "timed out waiting for Ctrl+Alt+Command+A; human confirmation is still required"

printf 'PASS_ISSUE_317_CARBON_BINDING_RETRY evidence=%s head=%s executableSHA256=%s\n' \
    "$EVIDENCE_DIR" "$EXPECTED_HEAD" "$EXECUTABLE_SHA256"
