#!/usr/bin/env bash
# E2E Test Module 2: Configured Shortcut Toggle ON/OFF
source "$(dirname "$0")/e2e-lib.sh"

MODULE_NAME="Configured Toggle ON/OFF"
e2e_maybe_launch "$MODULE_NAME"

echo ""
echo "=== $MODULE_NAME ==="

TEST_SHORTCUT=$(resolve_primary_test_shortcut) || e2e_skip_module "No supported shortcut configured"
TARGET_APP=$(shortcut_json_field "$TEST_SHORTCUT" appName)
TARGET_BUNDLE=$(shortcut_json_field "$TEST_SHORTCUT" bundleIdentifier)
TARGET_ROUTE=$(shortcut_json_field "$TEST_SHORTCUT" route)
TARGET_BUNDLE_PATTERN=$(regex_escape "$TARGET_BUNDLE")

echo "    Using $TARGET_APP ($TARGET_ROUTE route)"

# Ensure target running but not frontmost
ensure_shortcut_target_running "$TEST_SHORTCUT"
focus_non_target_app "$TARGET_BUNDLE"

# --- Part 1: Toggle ON ---
echo ""
echo "  -- Part 1: Toggle ON ($TARGET_APP) --"

PRE=$(log_line_count)
send_shortcut "$TEST_SHORTCUT"
sleep 3

SLICE=$(get_log_slice "$PRE")

assert_count_eq "$SLICE" "MATCHED: .* - $TARGET_BUNDLE_PATTERN" 1 "Single MATCHED for $TARGET_APP"
assert_contains "$SLICE" "SHORTCUT_TRACE_DECISION event=matched bundle=$TARGET_BUNDLE_PATTERN route=$TARGET_ROUTE" "Matched via $TARGET_ROUTE route"
assert_count_ge "$SLICE" "TOGGLE_ATTEMPT target=$TARGET_BUNDLE_PATTERN" 1 "Toggle attempt logged for $TARGET_APP"
assert_app_frontmost "$TARGET_BUNDLE" "$TARGET_APP is frontmost after toggle ON"

# --- Part 2: Toggle OFF ---
echo ""
echo "  -- Part 2: Toggle OFF ($TARGET_APP again) --"
sleep 1

PRE=$(log_line_count)
send_shortcut "$TEST_SHORTCUT"
sleep 3

SLICE=$(get_log_slice "$PRE")

assert_count_eq "$SLICE" "MATCHED: .* - $TARGET_BUNDLE_PATTERN" 1 "Single MATCHED for $TARGET_APP"
assert_count_ge "$SLICE" "HIDE_REQUEST" 1 "Hide request logged"
assert_count_ge "$SLICE" "TOGGLE_HIDE_CONFIRMED target=$TARGET_BUNDLE_PATTERN" 1 "Hide confirmed for $TARGET_APP"
assert_app_not_frontmost "$TARGET_BUNDLE" "$TARGET_APP not frontmost after toggle OFF"

e2e_maybe_stop
e2e_verdict "$MODULE_NAME"
