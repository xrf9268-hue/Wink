#!/usr/bin/env bash
# Shared library for Quickey E2E tests
# Source this file: source "$(dirname "$0")/e2e-lib.sh"

set -euo pipefail

# --- Constants ---
E2E_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$E2E_LIB_DIR/.." && pwd)"
APP_PATH="$PROJECT_DIR/build/Quickey.app"
LOG_FILE="$HOME/.config/Quickey/debug.log"
QUICKEY_BUNDLE_ID="com.quickey.app"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

FAILURES=0
PASSES=0

# --- Log helpers ---

log_line_count() {
    if [ -f "$LOG_FILE" ]; then
        wc -l < "$LOG_FILE" | tr -d ' '
    else
        echo 0
    fi
}

get_log_slice() {
    local pre_lines="$1"
    local post_lines
    post_lines=$(log_line_count)
    local new_lines=$((post_lines - pre_lines))
    if [ "$new_lines" -gt 0 ]; then
        tail -n "$new_lines" "$LOG_FILE"
    else
        echo ""
    fi
}

count_in_slice() {
    local slice="$1"
    local pattern="$2"
    if [ -z "$slice" ]; then
        echo 0
    else
        echo "$slice" | grep -c "$pattern" || true
    fi
}

# Wait for a log pattern to appear after $pre_lines, with timeout
wait_for_log() {
    local pattern="$1"
    local timeout="$2"
    local pre_lines="$3"
    local elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        if tail -n +"$((pre_lines + 1))" "$LOG_FILE" 2>/dev/null | grep -q "$pattern"; then
            return 0
        fi
        sleep 1
        ((elapsed++)) || true
    done
    return 1
}

# --- Assertion helpers ---

assert_contains() {
    local slice="$1" pattern="$2" name="$3"
    if echo "$slice" | grep -q "$pattern" 2>/dev/null; then
        echo -e "    ${GREEN}PASS${NC}: $name"
        ((PASSES++)) || true
    else
        echo -e "    ${RED}FAIL${NC}: $name (expected pattern: $pattern)"
        ((FAILURES++)) || true
    fi
}

assert_not_contains() {
    local slice="$1" pattern="$2" name="$3"
    if echo "$slice" | grep -q "$pattern" 2>/dev/null; then
        echo -e "    ${RED}FAIL${NC}: $name (unexpected pattern found: $pattern)"
        ((FAILURES++)) || true
    else
        echo -e "    ${GREEN}PASS${NC}: $name"
        ((PASSES++)) || true
    fi
}

assert_count_ge() {
    local slice="$1" pattern="$2" min="$3" name="$4"
    local count
    count=$(count_in_slice "$slice" "$pattern")
    if [ "$count" -ge "$min" ]; then
        echo -e "    ${GREEN}PASS${NC}: $name (count=$count >= $min)"
        ((PASSES++)) || true
    else
        echo -e "    ${RED}FAIL${NC}: $name (count=$count < $min)"
        ((FAILURES++)) || true
    fi
}

assert_count_le() {
    local slice="$1" pattern="$2" max="$3" name="$4"
    local count
    count=$(count_in_slice "$slice" "$pattern")
    if [ "$count" -le "$max" ]; then
        echo -e "    ${GREEN}PASS${NC}: $name (count=$count <= $max)"
        ((PASSES++)) || true
    else
        echo -e "    ${RED}FAIL${NC}: $name (count=$count > $max)"
        ((FAILURES++)) || true
    fi
}

assert_count_eq() {
    local slice="$1" pattern="$2" expected="$3" name="$4"
    local count
    count=$(count_in_slice "$slice" "$pattern")
    if [ "$count" -eq "$expected" ]; then
        echo -e "    ${GREEN}PASS${NC}: $name (count=$count)"
        ((PASSES++)) || true
    else
        echo -e "    ${RED}FAIL${NC}: $name (count=$count, expected $expected)"
        ((FAILURES++)) || true
    fi
}

assert_app_frontmost() {
    local bundle_id="$1" name="$2"
    local front
    front=$(get_frontmost_app)
    if [ "$front" = "$bundle_id" ]; then
        echo -e "    ${GREEN}PASS${NC}: $name"
        ((PASSES++)) || true
    else
        echo -e "    ${RED}FAIL${NC}: $name (expected $bundle_id, got $front)"
        ((FAILURES++)) || true
    fi
}

assert_app_not_frontmost() {
    local bundle_id="$1" name="$2"
    local front
    front=$(get_frontmost_app)
    if [ "$front" != "$bundle_id" ]; then
        echo -e "    ${GREEN}PASS${NC}: $name (front: $front)"
        ((PASSES++)) || true
    else
        echo -e "    ${YELLOW}WARN${NC}: $name ($bundle_id still frontmost)"
    fi
}

# --- osascript helpers ---

send_keystroke() {
    local key="$1" modifiers="$2"
    osascript -e "tell application \"System Events\" to keystroke \"$key\" using $modifiers"
}

send_keycode() {
    local code="$1"
    osascript -e "tell application \"System Events\" to key code $code"
}

# Send F19 followed immediately by a key code (Hyper Key testing)
send_hyper_combo() {
    local letter_code="$1"
    osascript -e "tell application \"System Events\"
    key code 80
    key code $letter_code
end tell"
}

# Send N rapid keystrokes in a single osascript (accurate sub-200ms timing)
send_rapid_keystrokes() {
    local key="$1" modifiers="$2" count="$3" delay="$4"
    local script="tell application \"System Events\""
    for i in $(seq 1 "$count"); do
        script="$script
    keystroke \"$key\" using $modifiers"
        if [ "$i" -lt "$count" ]; then
            script="$script
    delay $delay"
        fi
    done
    script="$script
end tell"
    osascript -e "$script"
}

# --- App state helpers ---

get_frontmost_app() {
    osascript -e 'tell application "System Events" to get bundle identifier of first application process whose frontmost is true' 2>/dev/null || echo "unknown"
}

ensure_app_running() {
    local app_name="$1"
    if ! pgrep -x "$app_name" > /dev/null 2>&1; then
        open -a "$app_name" --background 2>/dev/null || true
        sleep 0.5
    fi
}

ensure_app_stopped() {
    local app_name="$1"
    pkill -f "$app_name" 2>/dev/null || true
}

is_hyper_key_enabled() {
    local val
    val=$(defaults read "$QUICKEY_BUNDLE_ID" hyperKeyEnabled 2>/dev/null || echo "0")
    [ "$val" = "1" ]
}

# --- Module support ---

E2E_SKIP_LAUNCH=false
for arg in "$@"; do
    case "$arg" in
        --skip-launch) E2E_SKIP_LAUNCH=true ;;
    esac
done

e2e_launch_app() {
    if [ ! -d "$APP_PATH" ]; then
        echo -e "${RED}ERROR: Quickey.app not found at $APP_PATH${NC}"
        echo "    Run: ./scripts/package-app.sh"
        exit 1
    fi

    pkill -f "Quickey.app/Contents/MacOS/Quickey" 2>/dev/null || true
    sleep 1

    if [ -f "$LOG_FILE" ]; then
        cp "$LOG_FILE" "$LOG_FILE.e2e-backup"
    fi
    : > "$LOG_FILE"

    open "$APP_PATH"

    echo "    Waiting for event tap to start..."
    if wait_for_log "Event tap started" 30 0; then
        echo -e "    ${GREEN}Event tap started${NC}"
    else
        echo -e "    ${RED}Event tap failed to start within 30s${NC}"
        if grep -q "tapCreate.*failed" "$LOG_FILE" 2>/dev/null; then
            echo "    Check permissions:"
            echo "    System Settings > Privacy & Security > Accessibility -> add Quickey"
            echo "    System Settings > Privacy & Security > Input Monitoring -> add Quickey"
        else
            tail -20 "$LOG_FILE" 2>/dev/null || true
        fi
        exit 1
    fi
}

e2e_stop_app() {
    pkill -f "Quickey.app/Contents/MacOS/Quickey" 2>/dev/null || true
}

e2e_maybe_launch() {
    if [ "$E2E_SKIP_LAUNCH" = false ]; then
        echo "=== $1 (standalone) ==="
        e2e_launch_app
    fi
}

e2e_maybe_stop() {
    if [ "$E2E_SKIP_LAUNCH" = false ]; then
        e2e_stop_app
    fi
}

e2e_verdict() {
    local module_name="$1"
    echo ""
    if [ "$FAILURES" -gt 0 ]; then
        echo -e "${RED}${BOLD}$module_name: FAIL${NC} ($PASSES passed, $FAILURES failed)"
        return 1
    else
        echo -e "${GREEN}${BOLD}$module_name: PASS${NC} ($PASSES passed)"
        return 0
    fi
}
