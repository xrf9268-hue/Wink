#!/usr/bin/env bash
# E2E Test Module 1: Startup & Lifecycle
source "$(dirname "$0")/e2e-lib.sh"

MODULE_NAME="Startup & Lifecycle"
e2e_maybe_launch "$MODULE_NAME"

echo ""
echo "=== $MODULE_NAME ==="

REQUIREMENT=$(detect_capture_requirement "$SHORTCUTS_FILE" "$(hyper_key_enabled_flag)")

# Wait for first permission check (3s interval) before reading log
echo "    Waiting for first permission check..."
wait_for_log "checkPermission:" 10 0 || true

SLICE=$(get_log_slice 0)

assert_contains "$SLICE" "Wink starting" "App startup logged"
assert_contains "$SLICE" "attemptStart: shortcuts=[0-9][0-9]* triggerIndex=[0-9][0-9]*" "Shortcuts indexed"
assert_contains "$SLICE" "triggerIndex=[1-9]" "Shortcut count > 0"

if is_hyper_key_enabled; then
    assert_contains "$SLICE" "Hyper Key mapping re-applied" "Hyper Key mapping re-applied on launch"
else
    echo -e "    ${YELLOW}SKIP${NC}: Hyper Key not enabled"
fi

case "$REQUIREMENT" in
    standard)
        assert_contains "$SLICE" "checkPermission: ax=true .*carbon=true" "Standard capture ready"
        ;;
    hyper)
        assert_contains "$SLICE" "Event tap started" "Event tap running"
        assert_contains "$SLICE" "checkPermission: ax=true im=true .*eventTap=true" "Hyper capture ready"
        ;;
    mixed)
        assert_contains "$SLICE" "checkPermission: ax=true .*carbon=true" "Standard capture ready"
        assert_contains "$SLICE" "Event tap started" "Event tap running"
        assert_contains "$SLICE" "checkPermission: ax=true im=true .*eventTap=true" "Hyper capture ready"
        ;;
    none)
        echo -e "    ${YELLOW}SKIP${NC}: No enabled shortcuts configured"
        ;;
esac

# Permission timer: wait for second check cycle
echo "    Waiting 4s for permission timer cycle..."
sleep 4
SLICE_AFTER=$(get_log_slice 0)
assert_count_ge "$SLICE_AFTER" "checkPermission:" 2 "Permission timer running"

e2e_maybe_stop
e2e_verdict "$MODULE_NAME"
