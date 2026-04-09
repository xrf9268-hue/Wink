#!/usr/bin/env bash
# E2E Test Module 6: Multi-Shortcut Isolation
source "$(dirname "$0")/e2e-lib.sh"

MODULE_NAME="Multi-Shortcut Isolation"
e2e_maybe_launch "$MODULE_NAME"

echo ""
echo "=== $MODULE_NAME ==="

if ! bundle_has_configured_shortcut "com.apple.Safari" standard; then
    e2e_skip_module "Safari standard shortcut not configured"
fi

ensure_app_running "Safari"
sleep 1

# --- Step 1: Safari shortcut ---
echo ""
echo "  -- Step 1: Shift+Cmd+S -> only Safari --"

PRE=$(log_line_count)
send_keystroke "s" "{shift down, command down}"
sleep 3

SLICE=$(get_log_slice "$PRE")
assert_count_ge "$SLICE" "MATCHED: Safari" 1 "Safari shortcut matched"
assert_not_contains "$SLICE" "MATCHED: IINA" "IINA not triggered by Safari shortcut"

# --- Step 2: Hyper+A -> only IINA ---
if is_hyper_key_enabled && bundle_has_configured_shortcut "com.colliderli.iina" hyper; then
    _probe_cgevent
    echo ""
    echo "  -- Step 2: Hyper+A -> only IINA --"
    sleep 2

    PRE=$(log_line_count)
    send_hyper_combo 0
    sleep 3

    SLICE=$(get_log_slice "$PRE")
    assert_count_ge "$SLICE" "MATCHED: IINA" 1 "IINA shortcut matched"
    assert_not_contains "$SLICE" "MATCHED: Safari" "Safari not triggered by Hyper+A"

    ensure_app_stopped "IINA"
else
    echo ""
    echo -e "  -- Step 2: ${YELLOW}SKIP${NC} (IINA Hyper shortcut not configured) --"
fi

# --- Step 3: Safari again ---
echo ""
echo "  -- Step 3: Shift+Cmd+S again -> only Safari --"
sleep 2

PRE=$(log_line_count)
send_keystroke "s" "{shift down, command down}"
sleep 3

SLICE=$(get_log_slice "$PRE")
assert_count_ge "$SLICE" "MATCHED: Safari" 1 "Safari shortcut matched again"
assert_not_contains "$SLICE" "MATCHED: IINA" "IINA not triggered by second Safari press"

e2e_maybe_stop
e2e_verdict "$MODULE_NAME"
