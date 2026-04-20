#!/usr/bin/env bash
# Shared library for Wink E2E tests
# Source this file: source "$(dirname "$0")/e2e-lib.sh"

set -euo pipefail

# --- Constants ---
E2E_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$E2E_LIB_DIR/.." && pwd)"
APP_PATH="${E2E_APP_PATH:-$PROJECT_DIR/build/Wink.app}"
LOG_FILE="${E2E_LOG_FILE:-$HOME/.config/Wink/debug.log}"
APP_BUNDLE_ID="${E2E_BUNDLE_ID:-com.wink.app}"
SHORTCUTS_FILE="${E2E_SHORTCUTS_FILE:-$HOME/Library/Application Support/Wink/shortcuts.json}"
CGEVENT_HELPER="$E2E_LIB_DIR/cgevent-helper"
CGEVENT_SRC="$E2E_LIB_DIR/cgevent-helper.swift"

# Build CGEvent helper if source is newer than binary (or binary missing)
if [ ! -x "$CGEVENT_HELPER" ] || [ "$CGEVENT_SRC" -nt "$CGEVENT_HELPER" ]; then
    echo "  Building cgevent-helper..."
    swiftc -O "$CGEVENT_SRC" -o "$CGEVENT_HELPER" || {
        echo "ERROR: failed to compile cgevent-helper.swift" >&2
        exit 1
    }
fi

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

hyper_key_enabled_flag() {
    defaults read "$APP_BUNDLE_ID" hyperKeyEnabled 2>/dev/null || echo "0"
}

detect_capture_requirement() {
    local shortcuts_file="${1:-$SHORTCUTS_FILE}"
    local hyper_enabled="${2:-$(hyper_key_enabled_flag)}"

    if [ ! -f "$shortcuts_file" ]; then
        echo "none"
        return 0
    fi

    /usr/bin/ruby -rjson -e '
        shortcuts = JSON.parse(File.read(ARGV[0])) rescue []
        hyper_enabled = ARGV[1] == "1"
        standard = false
        hyper = false

        shortcuts.each do |shortcut|
          next if shortcut["isEnabled"] == false

          modifiers = Array(shortcut["modifierFlags"]).map { |flag| flag.to_s.downcase }
          is_hyper_combo = %w[command option control shift].all? { |flag| modifiers.include?(flag) }

          if hyper_enabled && is_hyper_combo
            hyper = true
          else
            standard = true
          end
        end

        if standard && hyper
          puts "mixed"
        elsif hyper
          puts "hyper"
        elsif standard
          puts "standard"
        else
          puts "none"
        end
    ' "$shortcuts_file" "$hyper_enabled"
}

bundle_has_configured_shortcut() {
    local bundle_id="$1"
    local expected_route="$2"
    local shortcuts_file="${3:-$SHORTCUTS_FILE}"
    local hyper_enabled="${4:-$(hyper_key_enabled_flag)}"

    if [ ! -f "$shortcuts_file" ]; then
        return 1
    fi

    /usr/bin/ruby -rjson -e '
        shortcuts = JSON.parse(File.read(ARGV[0])) rescue []
        hyper_enabled = ARGV[1] == "1"
        bundle_id = ARGV[2]
        expected_route = ARGV[3]

        matched = shortcuts.any? do |shortcut|
          next false if shortcut["isEnabled"] == false
          next false unless shortcut["bundleIdentifier"] == bundle_id

          modifiers = Array(shortcut["modifierFlags"]).map { |flag| flag.to_s.downcase }
          is_hyper_combo = %w[command option control shift].all? { |flag| modifiers.include?(flag) }
          route = hyper_enabled && is_hyper_combo ? "hyper" : "standard"

          route == expected_route
        end

        exit(matched ? 0 : 1)
    ' "$shortcuts_file" "$hyper_enabled" "$bundle_id" "$expected_route"
}

shortcut_inventory_json() {
    local shortcuts_file="${1:-$SHORTCUTS_FILE}"
    local hyper_enabled="${2:-$(hyper_key_enabled_flag)}"

    if [ ! -f "$shortcuts_file" ]; then
        echo "[]"
        return 0
    fi

    /usr/bin/ruby -rjson -e '
        key_codes = {
          "a" => 0, "s" => 1, "d" => 2, "f" => 3, "h" => 4, "g" => 5,
          "z" => 6, "x" => 7, "c" => 8, "v" => 9, "b" => 11, "q" => 12,
          "w" => 13, "e" => 14, "r" => 15, "y" => 16, "t" => 17, "1" => 18,
          "2" => 19, "3" => 20, "4" => 21, "6" => 22, "5" => 23, "=" => 24,
          "9" => 25, "7" => 26, "-" => 27, "8" => 28, "0" => 29, "]" => 30,
          "o" => 31, "u" => 32, "[" => 33, "i" => 34, "p" => 35, "l" => 37,
          "j" => 38, "k" => 40, ";" => 41, "\\" => 42, "," => 43,
          "/" => 44, "n" => 45, "m" => 46, "." => 47, "tab" => 48, "space" => 49,
          "`" => 50, "delete" => 51, "backspace" => 51, "escape" => 53, "esc" => 53,
          "command" => 55, "shift" => 56, "capslock" => 57, "option" => 58,
          "control" => 59, "rightshift" => 60, "rightoption" => 61, "rightcontrol" => 62,
          "function" => 63, "f17" => 64, "volumeup" => 72, "volumedown" => 73,
          "mute" => 74, "f18" => 79, "f19" => 80, "f20" => 90, "f5" => 96,
          "f6" => 97, "f7" => 98, "f3" => 99, "f8" => 100, "f9" => 101,
          "f11" => 103, "f13" => 105, "f16" => 106, "f14" => 107, "f10" => 109,
          "f12" => 111, "f15" => 113, "help" => 114, "home" => 115, "pageup" => 116,
          "forwarddelete" => 117, "f4" => 118, "end" => 119, "f2" => 120,
          "pagedown" => 121, "f1" => 122, "left" => 123, "right" => 124,
          "down" => 125, "up" => 126, "return" => 36, "enter" => 36
        }

        shortcuts = JSON.parse(File.read(ARGV[0])) rescue []
        hyper_enabled = ARGV[1] == "1"

        inventory = shortcuts.each_with_object([]) do |shortcut, entries|
          next if shortcut["isEnabled"] == false

          key_equivalent = shortcut["keyEquivalent"].to_s.downcase
          key_code = key_codes[key_equivalent]
          next if key_code.nil?

          modifiers = Array(shortcut["modifierFlags"]).map { |flag| flag.to_s.downcase }
          is_hyper_combo = %w[command option control shift].all? { |flag| modifiers.include?(flag) }
          route = hyper_enabled && is_hyper_combo ? "hyper" : "standard"

          entries << {
            "appName" => shortcut["appName"],
            "bundleIdentifier" => shortcut["bundleIdentifier"],
            "keyEquivalent" => key_equivalent,
            "modifierFlags" => modifiers,
            "route" => route,
            "keyCode" => key_code
          }
        end

        puts JSON.generate(inventory)
    ' "$shortcuts_file" "$hyper_enabled"
}

first_shortcut_for_route() {
    local expected_route="$1"
    local exclude_bundle="${2:-}"
    local shortcuts_file="${3:-$SHORTCUTS_FILE}"
    local hyper_enabled="${4:-$(hyper_key_enabled_flag)}"

    shortcut_inventory_json "$shortcuts_file" "$hyper_enabled" | /usr/bin/ruby -rjson -e '
        inventory = JSON.parse(STDIN.read) rescue []
        expected_route = ARGV[0]
        exclude_bundle = ARGV[1]

        shortcut = inventory.find do |entry|
          route_match = expected_route == "any" || entry["route"] == expected_route
          bundle_match = exclude_bundle.empty? || entry["bundleIdentifier"] != exclude_bundle
          route_match && bundle_match
        end

        if shortcut
          puts JSON.generate(shortcut)
        else
          exit 1
        end
    ' "$expected_route" "$exclude_bundle"
}

resolve_primary_test_shortcut() {
    local shortcuts_file="${1:-$SHORTCUTS_FILE}"
    local hyper_enabled="${2:-$(hyper_key_enabled_flag)}"

    first_shortcut_for_route standard "" "$shortcuts_file" "$hyper_enabled" ||
        first_shortcut_for_route hyper "" "$shortcuts_file" "$hyper_enabled"
}

resolve_isolation_shortcuts() {
    local shortcuts_file="${1:-$SHORTCUTS_FILE}"
    local hyper_enabled="${2:-$(hyper_key_enabled_flag)}"
    local primary
    local secondary
    local primary_bundle
    local primary_route

    primary=$(resolve_primary_test_shortcut "$shortcuts_file" "$hyper_enabled") || return 1
    primary_bundle=$(shortcut_json_field "$primary" bundleIdentifier)
    primary_route=$(shortcut_json_field "$primary" route)

    if [ "$primary_route" = "standard" ]; then
        secondary=$(first_shortcut_for_route hyper "$primary_bundle" "$shortcuts_file" "$hyper_enabled") ||
            secondary=$(first_shortcut_for_route any "$primary_bundle" "$shortcuts_file" "$hyper_enabled") ||
            return 1
    else
        secondary=$(first_shortcut_for_route standard "$primary_bundle" "$shortcuts_file" "$hyper_enabled") ||
            secondary=$(first_shortcut_for_route any "$primary_bundle" "$shortcuts_file" "$hyper_enabled") ||
            return 1
    fi

    printf '%s\n%s\n' "$primary" "$secondary"
}

shortcut_json_field() {
    local shortcut_json="$1"
    local field="$2"

    printf '%s' "$shortcut_json" | /usr/bin/ruby -rjson -e '
        shortcut = JSON.parse(STDIN.read) rescue nil
        exit 1 if shortcut.nil?

        value = shortcut[ARGV[0]]
        exit 1 if value.nil?

        if value.is_a?(Array) || value.is_a?(Hash)
          puts JSON.generate(value)
        else
          puts value
        end
    ' "$field"
}

regex_escape() {
    printf '%s' "$1" | /usr/bin/ruby -e 'print Regexp.escape(STDIN.read)'
}

_standard_capture_ready() {
    local log_file="${1:-$LOG_FILE}"
    grep -Eq 'attemptStart: .*carbon=true|checkPermission: ax=true .*carbon=true' "$log_file" 2>/dev/null
}

_hyper_capture_ready() {
    local log_file="${1:-$LOG_FILE}"
    grep -Eq 'Event tap started|attemptStart: .*eventTap=true|checkPermission: ax=true im=true .*eventTap=true' "$log_file" 2>/dev/null
}

_startup_log_ready() {
    local log_file="${1:-$LOG_FILE}"
    grep -q "starting, version" "$log_file" 2>/dev/null
}

capture_requirement_satisfied() {
    local requirement="$1"
    local log_file="${2:-$LOG_FILE}"

    case "$requirement" in
        standard)
            _standard_capture_ready "$log_file"
            ;;
        hyper)
            _hyper_capture_ready "$log_file"
            ;;
        mixed)
            _standard_capture_ready "$log_file" && _hyper_capture_ready "$log_file"
            ;;
        none)
            _startup_log_ready "$log_file"
            ;;
        *)
            return 1
            ;;
    esac
}

wait_for_capture_requirement() {
    local requirement="$1"
    local timeout="$2"
    local log_file="${3:-$LOG_FILE}"
    local elapsed=0

    while [ "$elapsed" -lt "$timeout" ]; do
        if capture_requirement_satisfied "$requirement" "$log_file"; then
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

send_keycode_with_modifiers() {
    local code="$1" modifiers="$2"
    osascript -e "tell application \"System Events\" to key code $code using $modifiers"
}

shortcut_modifiers_osascript() {
    local shortcut_json="$1"

    printf '%s' "$shortcut_json" | /usr/bin/ruby -rjson -e '
        shortcut = JSON.parse(STDIN.read) rescue {}
        modifiers = Array(shortcut["modifierFlags"]).map { |flag| flag.to_s.downcase }
        order = %w[command option control shift function]
        formatted = order.select { |flag| modifiers.include?(flag) }.map { |flag| "#{flag} down" }
        puts "{#{formatted.join(", ")}}"
    '
}

send_standard_shortcut() {
    local shortcut_json="$1"
    local key_code
    local modifiers

    key_code=$(shortcut_json_field "$shortcut_json" keyCode)
    modifiers=$(shortcut_modifiers_osascript "$shortcut_json")
    send_keycode_with_modifiers "$key_code" "$modifiers"
}

# Send F19 held + key tap for Hyper Key testing.
# Strategy: try CGEvent helper first (real hold simulation); fall back to
# osascript if CGEvent.post() fails (requires calling process to have
# Accessibility permission — not always available in CI/IDE terminals).
# The osascript fallback tests the deferred-keyUp path, which is the same
# code path triggered by real Caps Lock hardware (toggle quirk).
send_hyper_combo() {
    local letter_code="$1"
    if [ "$_HYPER_USE_OSASCRIPT" = "1" ]; then
        osascript -e "tell application \"System Events\"
    key code 80
    key code $letter_code
end tell"
    else
        "$CGEVENT_HELPER" combo 80 "$letter_code"
    fi
}

# Probe once whether CGEvent posting reaches the event tap.
# If not, fall back to osascript for the rest of the session.
_HYPER_USE_OSASCRIPT="0"
_HYPER_PROBED="0"
_probe_cgevent() {
    if [ ! -f "$LOG_FILE" ]; then _HYPER_USE_OSASCRIPT="1"; return; fi
    local pre
    pre=$(wc -l < "$LOG_FILE" | tr -d ' ')
    "$CGEVENT_HELPER" down 80 2>/dev/null
    usleep 50000 2>/dev/null || sleep 0.05
    "$CGEVENT_HELPER" up 80 2>/dev/null
    usleep 50000 2>/dev/null || sleep 0.05
    local slice
    slice=$(tail -n +"$((pre + 1))" "$LOG_FILE" 2>/dev/null || true)
    if echo "$slice" | grep -q "keyCode=80\|HYPER_FLAGS_CHANGED" 2>/dev/null; then
        _HYPER_USE_OSASCRIPT="0"
    else
        _HYPER_USE_OSASCRIPT="1"
    fi
    _HYPER_PROBED="1"
}

ensure_hyper_sender_ready() {
    if [ "$_HYPER_PROBED" != "1" ]; then
        _probe_cgevent
        _HYPER_PROBED="1"
    fi
}

send_hyper_shortcut_compat() {
    local key_code="$1"
    local previous_mode="${_HYPER_USE_OSASCRIPT:-0}"

    ensure_hyper_sender_ready
    _HYPER_USE_OSASCRIPT="1"
    send_hyper_combo "$key_code"
    _HYPER_USE_OSASCRIPT="$previous_mode"
}

# Send individual keyDown or keyUp via CGEvent (for precise event control)
send_cgevent_down() { "$CGEVENT_HELPER" down "$1"; }
send_cgevent_up()   { "$CGEVENT_HELPER" up "$1"; }

send_shortcut() {
    local shortcut_json="$1"
    local route
    local key_code

    route=$(shortcut_json_field "$shortcut_json" route)
    case "$route" in
        standard)
            send_standard_shortcut "$shortcut_json"
            ;;
        hyper)
            key_code=$(shortcut_json_field "$shortcut_json" keyCode)
            send_hyper_shortcut_compat "$key_code"
            ;;
        *)
            echo "ERROR: unsupported shortcut route '$route'" >&2
            return 1
            ;;
    esac
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

send_rapid_shortcuts() {
    local shortcut_json="$1"
    local count="$2"
    local delay="$3"
    local route
    local key_code
    local modifiers
    local script
    local i

    route=$(shortcut_json_field "$shortcut_json" route)

    if [ "$route" = "standard" ]; then
        key_code=$(shortcut_json_field "$shortcut_json" keyCode)
        modifiers=$(shortcut_modifiers_osascript "$shortcut_json")
        script="tell application \"System Events\""
        for i in $(seq 1 "$count"); do
            script="$script
    key code $key_code using $modifiers"
            if [ "$i" -lt "$count" ]; then
                script="$script
    delay $delay"
            fi
        done
        script="$script
end tell"
        osascript -e "$script"
        return 0
    fi

    for i in $(seq 1 "$count"); do
        send_shortcut "$shortcut_json"
        if [ "$i" -lt "$count" ]; then
            sleep "$delay"
        fi
    done
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

ensure_shortcut_target_running() {
    local shortcut_json="$1"
    local bundle_id
    local app_name

    bundle_id=$(shortcut_json_field "$shortcut_json" bundleIdentifier)
    app_name=$(shortcut_json_field "$shortcut_json" appName)

    if ! pgrep -x "$app_name" > /dev/null 2>&1; then
        open -b "$bundle_id" --background 2>/dev/null || open -a "$app_name" --background 2>/dev/null || true
        sleep 0.5
    fi
}

ensure_shortcut_target_stopped() {
    local shortcut_json="$1"
    local app_name

    app_name=$(shortcut_json_field "$shortcut_json" appName)
    ensure_app_stopped "$app_name"
}

focus_non_target_app() {
    local target_bundle="$1"

    if [ "$target_bundle" = "com.apple.finder" ]; then
        open -a "System Settings" 2>/dev/null || true
    else
        open -a Finder 2>/dev/null || true
    fi
    sleep 1
}

is_hyper_key_enabled() {
    [ "$(hyper_key_enabled_flag)" = "1" ]
}

# --- Module support ---

E2E_SKIP_LAUNCH=false
for arg in "$@"; do
    case "$arg" in
        --skip-launch) E2E_SKIP_LAUNCH=true ;;
    esac
done

e2e_launch_app() {
    local requirement
    if [ ! -d "$APP_PATH" ]; then
        echo -e "${RED}ERROR: Wink.app not found at $APP_PATH${NC}"
        echo "    Run: ./scripts/package-app.sh"
        exit 1
    fi

    pkill -f "Wink.app/Contents/MacOS/Wink" 2>/dev/null || true
    sleep 1

    if [ -f "$LOG_FILE" ]; then
        cp "$LOG_FILE" "$LOG_FILE.e2e-backup"
    fi
    mkdir -p "$(dirname "$LOG_FILE")"
    : > "$LOG_FILE"

    open "$APP_PATH"

    requirement=$(detect_capture_requirement "$SHORTCUTS_FILE" "$(hyper_key_enabled_flag)")

    echo "    Waiting for capture readiness (${requirement})..."
    if wait_for_capture_requirement "$requirement" 30 "$LOG_FILE"; then
        echo -e "    ${GREEN}Capture ready${NC} (${requirement})"
    else
        echo -e "    ${RED}Capture failed to become ready within 30s${NC} (${requirement})"
        if grep -q "tapCreate.*failed" "$LOG_FILE" 2>/dev/null; then
            echo "    Check permissions:"
            echo "    System Settings > Privacy & Security > Accessibility -> add Wink"
            echo "    System Settings > Privacy & Security > Input Monitoring -> add Wink"
        else
            tail -20 "$LOG_FILE" 2>/dev/null || true
        fi
        exit 1
    fi
}

e2e_stop_app() {
    pkill -f "Wink.app/Contents/MacOS/Wink" 2>/dev/null || true
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

e2e_skip_module() {
    local reason="$1"
    echo -e "    ${YELLOW}SKIP${NC}: $reason"
    e2e_maybe_stop
    exit 2
}
