#!/usr/bin/env bash
# E2E Test Module 2: Standard Shortcut Toggle ON/OFF
source "$(dirname "$0")/e2e-lib.sh"

MODULE_NAME="Standard Toggle ON/OFF"
e2e_maybe_launch "$MODULE_NAME"

echo ""
echo "=== $MODULE_NAME ==="

if ! bundle_has_configured_shortcut "com.apple.Safari" standard; then
    e2e_skip_module "Safari standard shortcut not configured"
fi

# Ensure Safari running but not frontmost
ensure_app_running "Safari"
open -a Finder  # push Safari to background
sleep 1

# --- Part 1: Toggle ON ---
echo ""
echo "  -- Part 1: Toggle ON (Shift+Cmd+S) --"

PRE=$(log_line_count)
send_keystroke "s" "{shift down, command down}"
sleep 3

SLICE=$(get_log_slice "$PRE")

assert_count_eq "$SLICE" "MATCHED: Safari" 1 "Single MATCHED: Safari"
assert_contains "$SLICE" "SHORTCUT_TRACE_DECISION event=matched bundle=com.apple.Safari route=standard" "Matched via standard route"
assert_count_ge "$SLICE" "TOGGLE_ATTEMPT" 1 "Toggle attempt logged"
assert_app_frontmost "com.apple.Safari" "Safari is frontmost after toggle ON"

# --- Part 2: Toggle OFF ---
echo ""
echo "  -- Part 2: Toggle OFF (Shift+Cmd+S again) --"
sleep 1

PRE=$(log_line_count)
send_keystroke "s" "{shift down, command down}"
sleep 3

SLICE=$(get_log_slice "$PRE")

assert_count_eq "$SLICE" "MATCHED: Safari" 1 "Single MATCHED: Safari"
assert_count_ge "$SLICE" "HIDE_REQUEST" 1 "Hide request logged"
assert_count_ge "$SLICE" "TOGGLE_HIDE_CONFIRMED" 1 "Hide confirmed"
assert_app_not_frontmost "com.apple.Safari" "Safari not frontmost after toggle OFF"

e2e_maybe_stop
e2e_verdict "$MODULE_NAME"
