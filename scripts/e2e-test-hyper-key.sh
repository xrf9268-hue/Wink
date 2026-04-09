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

if ! bundle_has_configured_shortcut "com.colliderli.iina" hyper; then
    e2e_skip_module "IINA Hyper shortcut not configured"
fi

# Probe CGEvent delivery; fall back to osascript if needed
_probe_cgevent
if [ "$_HYPER_USE_OSASCRIPT" = "1" ]; then
    echo -e "    ${YELLOW}NOTE${NC}: CGEvent.post() not available, using osascript (deferred-keyUp path)"
else
    echo -e "    ${GREEN}NOTE${NC}: Using CGEvent helper (real hold simulation)"
fi

# --- Part 1: Hold F19 + tap A -> IINA ---
echo ""
echo "  -- Part 1: Hold F19 + tap A -> IINA (real hold simulation) --"

PRE=$(log_line_count)
send_hyper_combo 0  # key code 0 = A  (combo: F19 down, A down, A up, F19 up)
sleep 3

SLICE=$(get_log_slice "$PRE")

echo ""
echo "  Log entries:"
echo "$SLICE" | head -20
echo ""

assert_count_ge "$SLICE" "EVENT_TAP_SWALLOW:" 1 "At least one event swallowed"
assert_count_ge "$SLICE" "MATCHED: IINA" 1 "MATCHED: IINA (Hyper+A triggered)"
assert_contains "$SLICE" "TOGGLE\[IINA\]" "Toggle lifecycle logged for IINA"
assert_not_contains "$SLICE" "DEBOUNCE_BLOCKED" "No debounce block on single Hyper combo"

# --- Part 2: Verify Hyper modifier injection ---
echo ""
echo "  -- Part 2: Verify Hyper modifier injection --"

# 1966080 = Ctrl+Opt+Shift+Cmd (0x1E0000)
assert_contains "$SLICE" "EVENT_TAP_SWALLOW:.*keyCode=0.*modifiers=1966080" "All 4 Hyper modifiers injected"

ensure_app_stopped "IINA"

# --- Part 3: Verify F19 hold/release lifecycle ---
echo ""
echo "  -- Part 3: F19 held state is cleared after combo --"

# Send another combo and verify no stale hyper state
PRE2=$(log_line_count)
send_hyper_combo 0  # Hyper+A again
sleep 3

SLICE2=$(get_log_slice "$PRE2")
assert_count_ge "$SLICE2" "MATCHED: IINA" 1 "Second Hyper+A also triggers IINA"
assert_not_contains "$SLICE2" "DEBOUNCE_BLOCKED" "No debounce block (separate combos)"

ensure_app_stopped "IINA"

e2e_maybe_stop
e2e_verdict "$MODULE_NAME"
