#!/usr/bin/env bash
# E2E Test Module 3: Hyper Key (Issue #83)
source "$(dirname "$0")/e2e-lib.sh"

MODULE_NAME="Hyper Key (CGEvent hold)"
e2e_maybe_launch "$MODULE_NAME"

echo ""
echo "=== $MODULE_NAME ==="

if ! is_hyper_key_enabled; then
    e2e_skip_module "Hyper Key not enabled"
fi

TEST_SHORTCUT=$(first_shortcut_for_route hyper) || e2e_skip_module "No Hyper shortcut configured"
TARGET_APP=$(shortcut_json_field "$TEST_SHORTCUT" appName)
TARGET_BUNDLE=$(shortcut_json_field "$TEST_SHORTCUT" bundleIdentifier)
TARGET_BUNDLE_PATTERN=$(regex_escape "$TARGET_BUNDLE")
TARGET_KEY_CODE=$(shortcut_json_field "$TEST_SHORTCUT" keyCode)

echo "    Using $TARGET_APP (hyper route)"

# Probe CGEvent delivery; fall back to osascript if needed
_probe_cgevent
if [ "$_HYPER_USE_OSASCRIPT" = "1" ]; then
    echo -e "    ${YELLOW}NOTE${NC}: CGEvent.post() not available, using osascript (deferred-keyUp path)"
else
    echo -e "    ${GREEN}NOTE${NC}: Using CGEvent helper (real hold simulation)"
fi

ensure_shortcut_target_running "$TEST_SHORTCUT"
focus_non_target_app "$TARGET_BUNDLE"

# --- Part 1: Hold F19 + tap configured Hyper shortcut ---
echo ""
echo "  -- Part 1: Hold F19 + tap key -> $TARGET_APP (real hold simulation) --"

PRE=$(log_line_count)
send_hyper_combo "$TARGET_KEY_CODE"
sleep 3

SLICE=$(get_log_slice "$PRE")

echo ""
echo "  Log entries:"
echo "$SLICE" | head -20
echo ""

assert_count_ge "$SLICE" "EVENT_TAP_SWALLOW:" 1 "At least one event swallowed"
assert_count_ge "$SLICE" "MATCHED: .* - $TARGET_BUNDLE_PATTERN" 1 "MATCHED: $TARGET_APP"
assert_contains "$SLICE" "TOGGLE_.*target=$TARGET_BUNDLE_PATTERN" "Toggle lifecycle logged for $TARGET_APP"
assert_not_contains "$SLICE" "DEBOUNCE_BLOCKED" "No debounce block on single Hyper combo"

# --- Part 2: Verify Hyper modifier injection ---
echo ""
echo "  -- Part 2: Verify Hyper modifier injection --"

# 1966080 = Ctrl+Opt+Shift+Cmd (0x1E0000)
assert_contains "$SLICE" "EVENT_TAP_SWALLOW:.*keyCode=$TARGET_KEY_CODE.*modifiers=1966080" "All 4 Hyper modifiers injected"

ensure_shortcut_target_stopped "$TEST_SHORTCUT"

# --- Part 3: Verify F19 hold/release lifecycle ---
echo ""
echo "  -- Part 3: F19 held state is cleared after combo --"

# Send another combo and verify no stale hyper state
PRE2=$(log_line_count)
send_hyper_combo "$TARGET_KEY_CODE"
sleep 3

SLICE2=$(get_log_slice "$PRE2")
assert_count_ge "$SLICE2" "MATCHED: .* - $TARGET_BUNDLE_PATTERN" 1 "Second Hyper shortcut also triggers $TARGET_APP"
assert_not_contains "$SLICE2" "DEBOUNCE_BLOCKED" "No debounce block (separate combos)"

ensure_shortcut_target_stopped "$TEST_SHORTCUT"

e2e_maybe_stop
e2e_verdict "$MODULE_NAME"
