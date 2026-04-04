#!/bin/bash
# Stop hook: detect rate-limit signals in the session transcript
# and write circuit breaker state for the next babysit-prs iteration.
#
# stdin: JSON with session_id, transcript_path, stop_reason, cwd, etc.
# stdout: nothing (always allow — never block to avoid infinite loops)
# See: docs/lessons-learned.md "Codex Stop Hook Infinite Loop"

set -euo pipefail

# Read hook input
INPUT=$(cat)
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)

# Determine state file location relative to project root
if [ -n "$CWD" ]; then
  STATE_FILE="$CWD/logs/loop-circuit-breaker.json"
else
  STATE_FILE="logs/loop-circuit-breaker.json"
fi

# If no transcript available, nothing to check
if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
  exit 0
fi

# Check the last 10 lines of transcript for rate-limit indicators.
# The transcript is JSONL; rate limit messages appear as assistant text
# or as rate_limit_event entries.
RATE_LIMITED=false
if tail -10 "$TRANSCRIPT" | grep -qi \
  'hit your limit\|rate.limit\|quota.*exceeded\|rateLimitType'; then
  RATE_LIMITED=true
fi

if [ "$RATE_LIMITED" = "false" ]; then
  exit 0
fi

# Ensure logs directory exists
mkdir -p "$(dirname "$STATE_FILE")"

# Read current state or initialize
if [ -f "$STATE_FILE" ]; then
  CURRENT_FAILURES=$(jq -r '.consecutiveFailures // 0' "$STATE_FILE" 2>/dev/null || echo "0")
else
  CURRENT_FAILURES=0
fi

FAILURES=$((CURRENT_FAILURES + 1))

# Exponential backoff: 30min * 2^(failures-1), capped at 4 hours (240 min)
BACKOFF_EXPONENT=$((FAILURES - 1))
[ "$BACKOFF_EXPONENT" -gt 3 ] && BACKOFF_EXPONENT=3
BACKOFF_MIN=$((30 * (1 << BACKOFF_EXPONENT)))

# Compute cooldown timestamp (portable: try GNU date first, then BSD)
if COOLDOWN=$(date -u -d "+${BACKOFF_MIN} minutes" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null); then
  : # GNU date succeeded
elif COOLDOWN=$(date -u -v+${BACKOFF_MIN}M +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null); then
  : # BSD date succeeded
else
  # Fallback: 4 hours from epoch-ish (best effort)
  COOLDOWN="2099-01-01T00:00:00Z"
fi

# Atomic write via temp file
TMPFILE=$(mktemp "${STATE_FILE}.XXXXXX")
cat > "$TMPFILE" <<EOF
{
  "consecutiveFailures": $FAILURES,
  "circuitState": "open",
  "cooldownUntil": "$COOLDOWN",
  "lastSuccessTimestamp": null
}
EOF
mv "$TMPFILE" "$STATE_FILE"

# Always exit 0 — never block
exit 0
