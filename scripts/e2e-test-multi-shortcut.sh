#!/usr/bin/env bash
# E2E Test Module 6: Multi-Shortcut Isolation
source "$(dirname "$0")/e2e-lib.sh"

MODULE_NAME="Multi-Shortcut Isolation"
e2e_maybe_launch "$MODULE_NAME"

echo ""
echo "=== $MODULE_NAME ==="

ISOLATION_RAW=$(resolve_isolation_shortcuts) || e2e_skip_module "Need at least two supported shortcuts"
mapfile -t ISOLATION_SHORTCUTS <<< "$ISOLATION_RAW"

SHORTCUT_ONE="${ISOLATION_SHORTCUTS[0]}"
SHORTCUT_TWO="${ISOLATION_SHORTCUTS[1]}"

APP_ONE=$(shortcut_json_field "$SHORTCUT_ONE" appName)
BUNDLE_ONE=$(shortcut_json_field "$SHORTCUT_ONE" bundleIdentifier)
ROUTE_ONE=$(shortcut_json_field "$SHORTCUT_ONE" route)
PATTERN_ONE=$(regex_escape "$BUNDLE_ONE")

APP_TWO=$(shortcut_json_field "$SHORTCUT_TWO" appName)
BUNDLE_TWO=$(shortcut_json_field "$SHORTCUT_TWO" bundleIdentifier)
ROUTE_TWO=$(shortcut_json_field "$SHORTCUT_TWO" route)
PATTERN_TWO=$(regex_escape "$BUNDLE_TWO")

echo "    Using $APP_ONE ($ROUTE_ONE route) and $APP_TWO ($ROUTE_TWO route)"

ensure_shortcut_target_running "$SHORTCUT_ONE"
ensure_shortcut_target_running "$SHORTCUT_TWO"
focus_non_target_app "$BUNDLE_ONE"

# --- Step 1: First shortcut ---
echo ""
echo "  -- Step 1: First shortcut -> only $APP_ONE --"

PRE=$(log_line_count)
send_shortcut "$SHORTCUT_ONE"
sleep 3

SLICE=$(get_log_slice "$PRE")
assert_count_ge "$SLICE" "MATCHED: .* - $PATTERN_ONE" 1 "$APP_ONE shortcut matched"
assert_not_contains "$SLICE" "MATCHED: .* - $PATTERN_TWO" "$APP_TWO not triggered by $APP_ONE shortcut"

# --- Step 2: Second shortcut ---
echo ""
echo "  -- Step 2: Second shortcut -> only $APP_TWO --"
sleep 2

PRE=$(log_line_count)
send_shortcut "$SHORTCUT_TWO"
sleep 3

SLICE=$(get_log_slice "$PRE")
assert_count_ge "$SLICE" "MATCHED: .* - $PATTERN_TWO" 1 "$APP_TWO shortcut matched"
assert_not_contains "$SLICE" "MATCHED: .* - $PATTERN_ONE" "$APP_ONE not triggered by $APP_TWO shortcut"

# --- Step 3: First shortcut again ---
echo ""
echo "  -- Step 3: First shortcut again -> only $APP_ONE --"
sleep 2

PRE=$(log_line_count)
send_shortcut "$SHORTCUT_ONE"
sleep 3

SLICE=$(get_log_slice "$PRE")
assert_count_ge "$SLICE" "MATCHED: .* - $PATTERN_ONE" 1 "$APP_ONE shortcut matched again"
assert_not_contains "$SLICE" "MATCHED: .* - $PATTERN_TWO" "$APP_TWO not triggered by second $APP_ONE press"

e2e_maybe_stop
e2e_verdict "$MODULE_NAME"
