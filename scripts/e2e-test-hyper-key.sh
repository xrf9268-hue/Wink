#!/usr/bin/env bash
# E2E Test Module 3: Hyper Key (Issue #83)
source "$(dirname "$0")/e2e-lib.sh"

MODULE_NAME="Hyper Key (F19 + Deferred)"
e2e_maybe_launch "$MODULE_NAME"

echo ""
echo "=== $MODULE_NAME ==="

if ! is_hyper_key_enabled; then
    echo -e "    ${YELLOW}SKIP${NC}: Hyper Key not enabled, cannot test"
    e2e_maybe_stop
    exit 0
fi

# --- Part 1: F19 + A -> IINA ---
echo ""
echo "  -- Part 1: F19 + A -> IINA (deferred keyUp mechanism) --"

PRE=$(log_line_count)
send_hyper_combo 0  # key code 0 = A
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

e2e_maybe_stop
e2e_verdict "$MODULE_NAME"
