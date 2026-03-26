#!/usr/bin/env bash
# E2E Test Module 5: Toggle Loop Prevention (Issue #80)
source "$(dirname "$0")/e2e-lib.sh"

MODULE_NAME="Toggle Loop Prevention"
MAX_MATCHED=2  # 1=toggle on, 2=toggle on+off; >2 indicates a loop
TEST_DURATION=10

e2e_maybe_launch "$MODULE_NAME"

echo ""
echo "=== $MODULE_NAME ==="

ensure_app_running "Safari"
sleep 1

echo "    Sending single Shift+Cmd+S, monitoring for ${TEST_DURATION}s..."

PRE=$(log_line_count)
send_keystroke "s" "{shift down, command down}"

# Poll with early exit if loop detected
elapsed=0
while [ "$elapsed" -lt "$TEST_DURATION" ]; do
    SLICE=$(get_log_slice "$PRE")
    MATCHED=$(count_in_slice "$SLICE" "MATCHED:")
    [ "$MATCHED" -gt "$MAX_MATCHED" ] && break
    sleep 1
    ((elapsed++)) || true
done

SLICE=$(get_log_slice "$PRE")
MATCHED=$(count_in_slice "$SLICE" "MATCHED:")
DEBOUNCED=$(count_in_slice "$SLICE" "DEBOUNCE_BLOCKED")
COOLDOWN=$(count_in_slice "$SLICE" "BLOCKED cooldown")
REENTRY=$(count_in_slice "$SLICE" "BLOCKED re-entry")

echo ""
echo "    Results (${elapsed}s):"
echo "    MATCHED:          $MATCHED"
echo "    DEBOUNCE_BLOCKED: $DEBOUNCED"
echo "    COOLDOWN_BLOCKED: $COOLDOWN"
echo "    RE-ENTRY_BLOCKED: $REENTRY"

echo ""
echo "  Log entries:"
echo "$SLICE" | head -30
echo ""

assert_count_le "$SLICE" "MATCHED:" "$MAX_MATCHED" "No toggle loop (MATCHED <= $MAX_MATCHED)"

if [ "$MATCHED" -le 2 ]; then
    echo -e "    ${CYAN}INFO${NC}: $MATCHED MATCHED = normal toggle behavior"
fi

e2e_maybe_stop
e2e_verdict "$MODULE_NAME"
