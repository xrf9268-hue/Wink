#!/usr/bin/env bash
# Runtime acceptance for issue #317's incremental Carbon reconciliation.
#
# This script never changes TCC. It launches an already packaged, signed
# carbon-binding-fault-injection bundle with automatic permission prompts
# suppressed, and requires Accessibility to have been granted beforehand.
#
# Optional environment:
#   EVIDENCE_DIR=/absolute/path/to/new-or-empty-evidence-directory
#   EXPECTED_HEAD=<40-character-commit-sha>
#   POLL_TIMEOUT_SECONDS=30
#   PHYSICAL_TIMEOUT_SECONDS=180
#   WAIT_FOR_PHYSICAL=1  # set to 0 for the non-physical metrics gate only
set -euo pipefail
umask 077

APP_NAME="Wink"
BUNDLE_ID="com.wink.app"
EXPECTED_PROFILE="carbon-binding-fault-injection"
FAULT_ARGUMENT="--validation-carbon-binding-fault=permanent-conflict:38:6400"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
FIXTURE_PATH="$SCRIPT_DIR/fixtures/issue-317-20-standard.json"
SHORTCUTS_FILE="$HOME/Library/Application Support/Wink/shortcuts.json"
LOG_FILE="$HOME/.config/Wink/debug.log"

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

for command_name in codesign defaults ditto git jq plutil pgrep ps python3 shasum tee; do
    require_command "$command_name"
done
[ "$(uname -s)" = "Darwin" ] || die "this runtime acceptance must run on macOS"

EXPECTED_HEAD="${EXPECTED_HEAD:-$(git -C "$PROJECT_DIR" rev-parse HEAD)}"
[[ "$EXPECTED_HEAD" =~ ^[0-9a-f]{40}$ ]] \
    || die "EXPECTED_HEAD must be one lowercase 40-character SHA: $EXPECTED_HEAD"
CURRENT_HEAD="$(git -C "$PROJECT_DIR" rev-parse HEAD)"
[ "$CURRENT_HEAD" = "$EXPECTED_HEAD" ] \
    || die "current HEAD $CURRENT_HEAD does not match EXPECTED_HEAD $EXPECTED_HEAD"
RESOLVED_EXPECTED_HEAD="$(git -C "$PROJECT_DIR" rev-parse --verify "$EXPECTED_HEAD^{commit}")"
[ "$RESOLVED_EXPECTED_HEAD" = "$EXPECTED_HEAD" ] \
    || die "EXPECTED_HEAD does not resolve to the exact current commit"

GIT_STATUS="$(git -C "$PROJECT_DIR" status --porcelain --untracked-files=all)"
[ -z "$GIT_STATUS" ] || {
    printf '%s\n' "$GIT_STATUS" >&2
    die "worktree must be clean so evidence is bound to one exact source state"
}

EXISTING_WINK_PIDS="$(pgrep -x "$APP_NAME" || true)"
[ -z "$EXISTING_WINK_PIDS" ] \
    || die "stop every existing Wink process before validation (pids: ${EXISTING_WINK_PIDS//$'\n'/,})"

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
mkdir -p "$EVIDENCE_DIR/bundles"
APP_PATH="$EVIDENCE_DIR/bundles/injected-Wink.app"
ditto "$BUILT_APP_PATH" "$APP_PATH"

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

EXECUTABLE_SHA256="$(shasum -a 256 "$EXECUTABLE" | awk '{print $1}')"
BUILT_EXECUTABLE="$BUILT_APP_PATH/Contents/MacOS/$APP_NAME"
BUILT_EXECUTABLE_SHA256="$(shasum -a 256 "$BUILT_EXECUTABLE" | awk '{print $1}')"
FIXTURE_SHA256="$(shasum -a 256 "$FIXTURE_PATH" | awk '{print $1}')"
[[ "$EXECUTABLE_SHA256" =~ ^[0-9a-f]{64}$ ]] || die "failed to calculate executable SHA-256"
[[ "$BUILT_EXECUTABLE_SHA256" =~ ^[0-9a-f]{64}$ ]] || die "failed to calculate built executable SHA-256"
[ "$EXECUTABLE_SHA256" = "$BUILT_EXECUTABLE_SHA256" ] \
    || die "preserved executable differs from the exact bundle built in this process"
[[ "$FIXTURE_SHA256" =~ ^[0-9a-f]{64}$ ]] || die "failed to calculate fixture SHA-256"

printf '%s\n' "$EXPECTED_HEAD" >"$EVIDENCE_DIR/head.txt"
printf '%s\n' "$BUILT_APP_PATH" >"$EVIDENCE_DIR/built-app-path.txt"
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
    printf 'head=%s\n' "$EXPECTED_HEAD"
    printf 'builtAppPath=%s\n' "$BUILT_APP_PATH"
    printf 'appPath=%s\n' "$APP_PATH"
    printf 'executablePath=%s\n' "$EXECUTABLE"
    printf 'executableSHA256=%s\n' "$EXECUTABLE_SHA256"
    printf 'fixturePath=%s\n' "$FIXTURE_PATH"
    printf 'fixtureSHA256=%s\n' "$FIXTURE_SHA256"
    printf 'profile=%s\n' "$ACTUAL_PROFILE"
    printf 'sourceRevision=%s\n' "$ACTUAL_SOURCE_REVISION"
    printf 'faultArgument=%s\n' "$FAULT_ARGUMENT"
} >"$EVIDENCE_DIR/identity.txt"

SHORTCUTS_EXISTED=0
LOG_EXISTED=0
SHORTCUTS_ORIGINAL_SHA256="absent"
LOG_ORIGINAL_SHA256="absent"
APP_PID=""
STATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wink-issue-317.XXXXXX")"

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

cleanup() {
    local status=$?
    local restore_failed=0
    trap - EXIT INT TERM
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

    if [ "$HYPER_KEY_EXISTED" -eq 1 ]; then
        if ! defaults write "$BUNDLE_ID" hyperKeyEnabled -bool "$ORIGINAL_HYPER_VALUE" \
            || [ "$(defaults read "$BUNDLE_ID" hyperKeyEnabled 2>/dev/null)" != "$ORIGINAL_HYPER_VALUE" ]; then
            printf 'WARNING: failed to restore hyperKeyEnabled=%s\n' "$ORIGINAL_HYPER_VALUE" >&2
            restore_failed=1
        fi
    else
        defaults delete "$BUNDLE_ID" hyperKeyEnabled >/dev/null 2>&1 || true
        if defaults read "$BUNDLE_ID" hyperKeyEnabled >/dev/null 2>&1; then
            printf 'WARNING: failed to restore absent hyperKeyEnabled key\n' >&2
            restore_failed=1
        fi
    fi

    {
        printf 'shortcutsOriginalSHA256=%s\n' "$SHORTCUTS_ORIGINAL_SHA256"
        printf 'debugLogOriginalSHA256=%s\n' "$LOG_ORIGINAL_SHA256"
        printf 'hyperKeyOriginallyPresent=%s\n' "$HYPER_KEY_EXISTED"
        printf 'hyperKeyOriginalValue=%s\n' "${ORIGINAL_HYPER_VALUE:-absent}"
        printf 'restored=%s\n' "$([ "$restore_failed" -eq 0 ] && printf true || printf false)"
    } >"$EVIDENCE_DIR/restoration.txt"

    rm -rf "$STATE_DIR" || restore_failed=1
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

LAUNCH_OUTPUT="$EVIDENCE_DIR/launch-stdout-stderr.txt"
"$EXECUTABLE" \
    --suppress-automatic-permission-prompts \
    "$FAULT_ARGUMENT" \
    >>"$LAUNCH_OUTPUT" 2>&1 &
APP_PID=$!
printf '%s\n' "$APP_PID" >"$EVIDENCE_DIR/app-pid.txt"
printf '%q %q %q\n' \
    "$EXECUTABLE" \
    "--suppress-automatic-permission-prompts" \
    "$FAULT_ARGUMENT" \
    >"$EVIDENCE_DIR/launch-command.txt"

sleep 1
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
    .pollCount >= 5
    and .syncCount == (.pollCount + 1)
    and .retrySyncCount == .pollCount
    and (.finalFaultCounters.forwardedRegisterCalls | tonumber) == 19
    and (.finalFaultCounters.unregisterCalls | tonumber) == 0
' "$EVIDENCE_DIR/runtime-summary.json" >/dev/null \
    || die "runtime summary failed its independent jq integrity check"

PHYSICAL_PRE_LINES="$(wc -l <"$LOG_FILE" | tr -d ' ')"
touch "$EVIDENCE_DIR/READY_FOR_PHYSICAL_CTRL_ALT_COMMAND_A"
printf 'READY_FOR_PHYSICAL_CTRL_ALT_COMMAND_A\n'

if [ "$WAIT_FOR_PHYSICAL" -eq 1 ]; then
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
else
    printf 'Physical observation skipped because WAIT_FOR_PHYSICAL=0.\n' \
        >"$EVIDENCE_DIR/physical-input-skipped.txt"
fi

printf 'PASS_ISSUE_317_CARBON_BINDING_RETRY evidence=%s head=%s executableSHA256=%s\n' \
    "$EVIDENCE_DIR" "$EXPECTED_HEAD" "$EXECUTABLE_SHA256"
