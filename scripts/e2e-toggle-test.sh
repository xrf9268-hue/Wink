#!/usr/bin/env bash
# End-to-end test for issue #80: toggle loop detection
# Usage: ./scripts/e2e-toggle-test.sh
#
# Prerequisites:
# - cliclick installed (brew install cliclick)
# - Quickey.app built (./scripts/package-app.sh)
# - Accessibility + Input Monitoring permissions granted to Quickey.app
#
# This script:
# 1. Clears the debug log
# 2. Launches Quickey
# 3. Waits for event tap to start
# 4. Sends a shortcut key via cliclick
# 5. Monitors the log for toggle loop patterns
# 6. Kills Quickey
# 7. Analyzes the results
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_PATH="$PROJECT_DIR/build/Quickey.app"
LOG_FILE="$HOME/.config/Quickey/debug.log"
LOG_BACKUP="$HOME/.config/Quickey/debug.log.e2e-backup"
TEST_DURATION=10  # seconds to monitor after shortcut press
LOOP_THRESHOLD=3  # number of MATCHED entries that indicate a loop

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo "=== Quickey E2E Toggle Loop Test (Issue #80) ==="
echo ""

# Check prerequisites
if ! command -v cliclick &>/dev/null; then
    echo -e "${RED}ERROR: cliclick not installed. Run: brew install cliclick${NC}"
    exit 1
fi

if [ ! -d "$APP_PATH" ]; then
    echo -e "${RED}ERROR: Quickey.app not found at $APP_PATH. Run: ./scripts/package-app.sh${NC}"
    exit 1
fi

# Kill any existing Quickey instance
pkill -f "Quickey.app/Contents/MacOS/Quickey" 2>/dev/null || true
sleep 1

# Backup and clear the debug log
if [ -f "$LOG_FILE" ]; then
    cp "$LOG_FILE" "$LOG_BACKUP"
    echo "    Backed up debug.log to debug.log.e2e-backup"
fi
: > "$LOG_FILE"
echo "    Cleared debug.log"

# Launch Quickey
echo ""
echo "==> Launching Quickey.app..."
open "$APP_PATH"

# Wait for event tap to start
echo "    Waiting for event tap to start..."
TAP_STARTED=false
for i in $(seq 1 30); do
    if grep -q "Event tap started" "$LOG_FILE" 2>/dev/null; then
        TAP_STARTED=true
        echo -e "    ${GREEN}Event tap started successfully${NC}"
        break
    fi
    if grep -q "tapCreate.*failed" "$LOG_FILE" 2>/dev/null; then
        echo -e "${RED}ERROR: Event tap creation failed. Check permissions:${NC}"
        echo "    System Settings > Privacy & Security > Accessibility → add Quickey"
        echo "    System Settings > Privacy & Security > Input Monitoring → add Quickey"
        pkill -f "Quickey.app/Contents/MacOS/Quickey" 2>/dev/null || true
        exit 1
    fi
    sleep 1
done

if [ "$TAP_STARTED" = false ]; then
    echo -e "${YELLOW}WARNING: Event tap did not start within 30s. Checking log...${NC}"
    cat "$LOG_FILE"
    echo ""
    echo "You may need to grant permissions manually:"
    echo "    System Settings > Privacy & Security > Accessibility → add Quickey"
    echo "    System Settings > Privacy & Security > Input Monitoring → add Quickey"
    echo "Then re-run this script."
    pkill -f "Quickey.app/Contents/MacOS/Quickey" 2>/dev/null || true
    exit 1
fi

# Record the line count before the test
PRE_LINES=$(wc -l < "$LOG_FILE" | tr -d ' ')
echo ""
echo "==> Sending Safari shortcut (Shift+Cmd+S) via osascript..."
echo "    (Test duration: ${TEST_DURATION}s)"

# Make sure Safari is running
open -a Safari --background 2>/dev/null || true
sleep 1

# Send the shortcut via System Events (osascript goes through session event tap)
osascript -e 'tell application "System Events" to keystroke "s" using {shift down, command down}'

# Monitor the log for the test duration
echo "    Monitoring debug.log for toggle loop patterns..."
sleep "$TEST_DURATION"

# Count MATCHED entries after our test
POST_LINES=$(wc -l < "$LOG_FILE" | tr -d ' ')
NEW_LINES=$((POST_LINES - PRE_LINES))

# Extract the test window from the log (use tr to strip whitespace from grep -c)
MATCHED_COUNT=$(tail -n "$NEW_LINES" "$LOG_FILE" | grep -c "MATCHED:" | tr -d ' ')
BLOCKED_DEBOUNCE=$(tail -n "$NEW_LINES" "$LOG_FILE" | grep -c "DEBOUNCE_BLOCKED" | tr -d ' ')
BLOCKED_COOLDOWN=$(tail -n "$NEW_LINES" "$LOG_FILE" | grep -c "BLOCKED cooldown" | tr -d ' ')
BLOCKED_REENTRY=$(tail -n "$NEW_LINES" "$LOG_FILE" | grep -c "BLOCKED re-entry" | tr -d ' ')
SWALLOW_COUNT=$(tail -n "$NEW_LINES" "$LOG_FILE" | grep -c "EVENT_TAP_SWALLOW" | tr -d ' ')

echo ""
echo "=== Test Results ==="
echo "    New log lines:        $NEW_LINES"
echo "    EVENT_TAP_SWALLOW:    $SWALLOW_COUNT"
echo "    MATCHED:              $MATCHED_COUNT"
echo "    DEBOUNCE_BLOCKED:     $BLOCKED_DEBOUNCE"
echo "    TOGGLE COOLDOWN:      $BLOCKED_COOLDOWN"
echo "    RE-ENTRY BLOCKED:     $BLOCKED_REENTRY"
echo ""

# Show the relevant log entries
echo "=== Log Entries (test window) ==="
tail -n "$NEW_LINES" "$LOG_FILE" | head -50
echo ""

# Verdict
if [ "$MATCHED_COUNT" -gt "$LOOP_THRESHOLD" ]; then
    echo -e "${RED}FAIL: Toggle loop detected! $MATCHED_COUNT MATCHED entries in ${TEST_DURATION}s${NC}"
    echo "    This indicates the fix did not fully prevent the loop."
    echo ""
    echo "    Defense layers that fired:"
    [ "$BLOCKED_DEBOUNCE" -gt 0 ] && echo "      - Debounce blocked: $BLOCKED_DEBOUNCE events"
    [ "$BLOCKED_COOLDOWN" -gt 0 ] && echo "      - Toggle cooldown blocked: $BLOCKED_COOLDOWN events"
    [ "$BLOCKED_REENTRY" -gt 0 ] && echo "      - Re-entry guard blocked: $BLOCKED_REENTRY events"
    RESULT=1
elif [ "$MATCHED_COUNT" -le 2 ]; then
    echo -e "${GREEN}PASS: No toggle loop detected. $MATCHED_COUNT MATCHED entries in ${TEST_DURATION}s${NC}"
    if [ "$MATCHED_COUNT" -eq 2 ]; then
        echo "    (2 MATCHED = normal toggle on + toggle off)"
    elif [ "$MATCHED_COUNT" -eq 1 ]; then
        echo "    (1 MATCHED = single toggle on)"
    fi
    RESULT=0
else
    echo -e "${YELLOW}WARNING: $MATCHED_COUNT MATCHED entries. Possible mild loop.${NC}"
    RESULT=0
fi

# Cleanup: kill Quickey
echo ""
echo "==> Stopping Quickey..."
pkill -f "Quickey.app/Contents/MacOS/Quickey" 2>/dev/null || true
echo "    Done."

exit $RESULT
