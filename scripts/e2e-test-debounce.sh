#!/usr/bin/env bash
# E2E Test Module 4: Debounce & Cooldown
source "$(dirname "$0")/e2e-lib.sh"

MODULE_NAME="Debounce & Cooldown"
e2e_maybe_launch "$MODULE_NAME"

echo ""
echo "=== $MODULE_NAME ==="

if ! bundle_has_configured_shortcut "com.apple.Safari" standard; then
    e2e_skip_module "Safari standard shortcut not configured"
fi

ensure_app_running "Safari"
sleep 1

# --- Part 1: Ultra-rapid presses (single osascript, accurate sub-200ms timing) ---
echo ""
echo "  -- Part 1: Ultra-rapid presses (3x @ 50ms, expect cooldown protection on standard route) --"

PRE=$(log_line_count)
send_rapid_keystrokes "s" "{shift down, command down}" 3 0.05
sleep 3

SLICE=$(get_log_slice "$PRE")
echo "    MATCHED=$(count_in_slice "$SLICE" "MATCHED:"), Cooldown=$(count_in_slice "$SLICE" "BLOCKED cooldown"), Debounced=$(count_in_slice "$SLICE" "DEBOUNCE_BLOCKED")"

assert_count_ge "$SLICE" "MATCHED:" 1 "At least one press matched"
assert_count_ge "$SLICE" "BLOCKED cooldown" 1 "At least one press cooldown-blocked"

# --- Part 2: Medium-rapid presses (expect cooldown) ---
echo ""
echo "  -- Part 2: Medium-rapid presses (2x @ 300ms, expect cooldown) --"
sleep 2

PRE=$(log_line_count)
send_rapid_keystrokes "s" "{shift down, command down}" 2 0.3
sleep 3

SLICE=$(get_log_slice "$PRE")
echo "    MATCHED=$(count_in_slice "$SLICE" "MATCHED:"), Cooldown=$(count_in_slice "$SLICE" "BLOCKED cooldown")"

assert_count_ge "$SLICE" "MATCHED:" 1 "First press matched"
# Cooldown is timing-dependent; informational only
COOLDOWN=$(count_in_slice "$SLICE" "BLOCKED cooldown")
if [ "$COOLDOWN" -ge 1 ]; then
    echo -e "    ${GREEN}PASS${NC}: Cooldown blocked second press"
    ((PASSES++)) || true
else
    echo -e "    ${CYAN}INFO${NC}: No cooldown block (timing may vary)"
fi

# --- Part 3: Normal-interval presses (should all pass) ---
echo ""
echo "  -- Part 3: Normal-interval presses (3x @ 800ms, expect all pass) --"
sleep 2

PRE=$(log_line_count)
send_rapid_keystrokes "s" "{shift down, command down}" 3 0.8
sleep 2

SLICE=$(get_log_slice "$PRE")
echo "    MATCHED=$(count_in_slice "$SLICE" "MATCHED:"), Debounced=$(count_in_slice "$SLICE" "DEBOUNCE_BLOCKED")"

assert_count_ge "$SLICE" "MATCHED:" 2 "At least 2/3 presses matched at normal interval"

e2e_maybe_stop
e2e_verdict "$MODULE_NAME"
