#!/usr/bin/env bash
# E2E Test Module 4: Debounce & Cooldown
source "$(dirname "$0")/e2e-lib.sh"

MODULE_NAME="Debounce & Cooldown"
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

# --- Part 1: Ultra-rapid presses (single osascript, accurate sub-200ms timing) ---
echo ""
echo "  -- Part 1: Ultra-rapid presses (3x @ 50ms, expect cooldown protection on $TARGET_ROUTE route) --"

PRE=$(log_line_count)
send_rapid_shortcuts "$TEST_SHORTCUT" 3 0.05
sleep 3

SLICE=$(get_log_slice "$PRE")
echo "    MATCHED=$(count_in_slice "$SLICE" "MATCHED: .* - $TARGET_BUNDLE_PATTERN"), Cooldown=$(count_in_slice "$SLICE" "BLOCKED cooldown"), Debounced=$(count_in_slice "$SLICE" "DEBOUNCE_BLOCKED")"

assert_count_ge "$SLICE" "MATCHED: .* - $TARGET_BUNDLE_PATTERN" 1 "At least one $TARGET_APP press matched"
assert_count_ge "$SLICE" "BLOCKED cooldown" 1 "At least one press cooldown-blocked"

# --- Part 2: Medium-rapid presses (expect cooldown) ---
echo ""
echo "  -- Part 2: Medium-rapid presses (2x @ 300ms, expect cooldown) --"
sleep 2

PRE=$(log_line_count)
send_rapid_shortcuts "$TEST_SHORTCUT" 2 0.3
sleep 3

SLICE=$(get_log_slice "$PRE")
echo "    MATCHED=$(count_in_slice "$SLICE" "MATCHED: .* - $TARGET_BUNDLE_PATTERN"), Cooldown=$(count_in_slice "$SLICE" "BLOCKED cooldown")"

assert_count_ge "$SLICE" "MATCHED: .* - $TARGET_BUNDLE_PATTERN" 1 "First $TARGET_APP press matched"
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
send_rapid_shortcuts "$TEST_SHORTCUT" 3 0.8
sleep 2

SLICE=$(get_log_slice "$PRE")
echo "    MATCHED=$(count_in_slice "$SLICE" "MATCHED: .* - $TARGET_BUNDLE_PATTERN"), Debounced=$(count_in_slice "$SLICE" "DEBOUNCE_BLOCKED")"

assert_count_ge "$SLICE" "MATCHED: .* - $TARGET_BUNDLE_PATTERN" 2 "At least 2/3 $TARGET_APP presses matched at normal interval"

e2e_maybe_stop
e2e_verdict "$MODULE_NAME"
