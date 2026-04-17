#!/usr/bin/env bash
# E2E Test Module 5: Toggle Loop Prevention (Issue #80)
source "$(dirname "$0")/e2e-lib.sh"

MODULE_NAME="Toggle Loop Prevention"
MAX_MATCHED=2  # 1=toggle on, 2=toggle on+off; >2 indicates a loop
TEST_DURATION=10

e2e_maybe_launch "$MODULE_NAME"

echo ""
echo "=== $MODULE_NAME ==="

TEST_SHORTCUT=$(resolve_primary_test_shortcut) || e2e_skip_module "No supported shortcut configured"
TARGET_APP=$(shortcut_json_field "$TEST_SHORTCUT" appName)
TARGET_BUNDLE=$(shortcut_json_field "$TEST_SHORTCUT" bundleIdentifier)
TARGET_ROUTE=$(shortcut_json_field "$TEST_SHORTCUT" route)
TARGET_BUNDLE_PATTERN=$(regex_escape "$TARGET_BUNDLE")

echo "    Using $TARGET_APP ($TARGET_ROUTE route)"

ensure_shortcut_target_running "$TEST_SHORTCUT"
focus_non_target_app "$TARGET_BUNDLE"

echo "    Sending single $TARGET_APP shortcut, monitoring for ${TEST_DURATION}s..."

PRE=$(log_line_count)
send_shortcut "$TEST_SHORTCUT"

# Poll with early exit if loop detected
elapsed=0
while [ "$elapsed" -lt "$TEST_DURATION" ]; do
    SLICE=$(get_log_slice "$PRE")
    MATCHED=$(count_in_slice "$SLICE" "MATCHED: .* - $TARGET_BUNDLE_PATTERN")
    [ "$MATCHED" -gt "$MAX_MATCHED" ] && break
    sleep 1
    ((elapsed++)) || true
done

SLICE=$(get_log_slice "$PRE")
MATCHED=$(count_in_slice "$SLICE" "MATCHED: .* - $TARGET_BUNDLE_PATTERN")
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

assert_count_le "$SLICE" "MATCHED: .* - $TARGET_BUNDLE_PATTERN" "$MAX_MATCHED" "No toggle loop for $TARGET_APP (MATCHED <= $MAX_MATCHED)"

if [ "$MATCHED" -le 2 ]; then
    echo -e "    ${CYAN}INFO${NC}: $MATCHED MATCHED = normal toggle behavior"
fi

e2e_maybe_stop
e2e_verdict "$MODULE_NAME"
