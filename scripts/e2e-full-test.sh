#!/usr/bin/env bash
# Quickey E2E Full Test Suite
# Launches Quickey once, runs all test modules, reports summary
#
# Usage: ./scripts/e2e-full-test.sh
#
# Prerequisites:
# - Quickey.app built (./scripts/package-app.sh)
# - Accessibility + Input Monitoring permissions granted
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/e2e-lib.sh"

trap 'rm -f /tmp/e2e-module-output-*.txt' EXIT

echo ""
echo -e "${BOLD}=== Quickey E2E Full Test Suite ===${NC}"
echo ""

e2e_launch_app
echo ""

# --- Run test modules ---
MODULES=(
    "e2e-test-startup.sh:Startup & Lifecycle"
    "e2e-test-standard-toggle.sh:Standard Toggle ON/OFF"
    "e2e-test-hyper-key.sh:Hyper Key (F19 + Deferred)"
    "e2e-test-debounce.sh:Debounce & Cooldown"
    "e2e-test-loop-prevention.sh:Toggle Loop Prevention"
    "e2e-test-multi-shortcut.sh:Multi-Shortcut Isolation"
)

TOTAL=${#MODULES[@]}
PASSED=0
FAILED=0
WARNED=0
RESULTS=()

for i in "${!MODULES[@]}"; do
    IFS=: read -r script name <<< "${MODULES[$i]}"
    num=$((i + 1))
    printf "[%d/%d] %-35s " "$num" "$TOTAL" "$name"

    set +e
    bash "$SCRIPT_DIR/$script" --skip-launch > /tmp/e2e-module-output-$num.txt 2>&1
    EXIT_CODE=$?
    set -e

    case $EXIT_CODE in
        0)
            echo -e "${GREEN}PASS${NC}"
            ((PASSED++)) || true
            RESULTS+=("PASS")
            ;;
        2)
            echo -e "${YELLOW}WARN${NC}"
            ((WARNED++)) || true
            RESULTS+=("WARN")
            ;;
        *)
            echo -e "${RED}FAIL${NC}"
            ((FAILED++)) || true
            RESULTS+=("FAIL")
            ;;
    esac
done

echo ""
echo "==> Stopping Quickey..."
e2e_stop_app
echo "    Done."

# --- Summary ---
echo ""
echo -e "${BOLD}=== Results ===${NC}"
echo ""

for i in "${!MODULES[@]}"; do
    IFS=: read -r script name <<< "${MODULES[$i]}"
    num=$((i + 1))
    result="${RESULTS[$i]}"
    case $result in
        PASS) color="$GREEN" ;;
        WARN) color="$YELLOW" ;;
        *)    color="$RED" ;;
    esac
    printf "  [%d/%d] %-35s %b%s%b\n" "$num" "$TOTAL" "$name" "$color" "$result" "$NC"
done

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo -e "${GREEN}${BOLD}All $TOTAL tests passed${NC} ($WARNED warnings)"
else
    echo -e "${RED}${BOLD}$FAILED/$TOTAL tests failed${NC} ($PASSED passed, $WARNED warnings)"
    echo ""
    echo "Failed module details:"
    for i in "${!MODULES[@]}"; do
        if [ "${RESULTS[$i]}" = "FAIL" ]; then
            IFS=: read -r script name <<< "${MODULES[$i]}"
            num=$((i + 1))
            echo ""
            echo -e "  ${RED}--- [$num] $name ---${NC}"
            cat /tmp/e2e-module-output-$num.txt
        fi
    done
fi

[ "$FAILED" -gt 0 ] && exit 1
exit 0
