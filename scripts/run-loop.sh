#!/usr/bin/env bash
set -euo pipefail

# ── Configuration ──
REPO="$HOME/developer/Quickey"
INTERVAL=1800                  # 30 minutes
MAX_BACKOFF_TOTAL=14400        # 4 hours in seconds
LOG_DIR="$REPO/logs"
LOG_FILE="$LOG_DIR/loop-$(date '+%Y-%m-%d').log"

# ── Signal handling ──
RUNNING=true
trap 'echo "[loop] $(date '"'"'+%Y-%m-%d %H:%M:%S'"'"') Received stop signal, finishing current iteration..." | stdbuf -oL tee -a "$LOG_FILE"; RUNNING=false' SIGINT SIGTERM SIGHUP

# ── Init ──
cd "$REPO"
mkdir -p "$LOG_DIR"
consecutive_failures=0
current_backoff=$INTERVAL
total_backoff=0

echo "[loop] Starting Quickey loop job (interval: ${INTERVAL}s)" | stdbuf -oL tee -a "$LOG_FILE"

# ── Main loop ──
while $RUNNING; do
  echo "[loop] $(date '+%Y-%m-%d %H:%M:%S') - Running iteration..." | stdbuf -oL tee -a "$LOG_FILE"

  if claude --bare \
       --add-dir . \
       --model opus \
       --max-turns 50 \
       --dangerously-skip-permissions \
       --output-format text \
       -p "$(cat "$REPO/docs/loop-prompt.md")" \
       2>&1 | stdbuf -oL tee -a "$LOG_FILE"; then
    consecutive_failures=0
    current_backoff=$INTERVAL
    total_backoff=0
    echo "[loop] $(date '+%Y-%m-%d %H:%M:%S') - Iteration succeeded." | stdbuf -oL tee -a "$LOG_FILE"
  else
    # || true prevents set -e from exiting when consecutive_failures increments from 0
    # (bash arithmetic (( 0++ )) returns exit code 1)
    ((consecutive_failures++)) || true
    echo "[loop] $(date '+%Y-%m-%d %H:%M:%S') - Iteration FAILED (consecutive: $consecutive_failures, backoff: ${current_backoff}s, total: ${total_backoff}s)" | stdbuf -oL tee -a "$LOG_FILE"

    # Check circuit breaker BEFORE sleeping: accumulate first, then decide
    total_backoff=$((total_backoff + current_backoff))
    if [ "$total_backoff" -ge "$MAX_BACKOFF_TOTAL" ]; then
      echo "[loop] CIRCUIT BREAKER: total backoff ${total_backoff}s >= ${MAX_BACKOFF_TOTAL}s. Stopping." | stdbuf -oL tee -a "$LOG_FILE"
      break
    fi

    # Exponential backoff sleep (interruptible via signal)
    if $RUNNING; then
      echo "[loop] Backing off for ${current_backoff}s..." | stdbuf -oL tee -a "$LOG_FILE"
      sleep "$current_backoff" &
      wait $! || true
      current_backoff=$((current_backoff * 2))
    fi
    continue
  fi

  # Normal interval sleep (interruptible)
  if $RUNNING; then
    echo "[loop] $(date '+%Y-%m-%d %H:%M:%S') - Sleeping ${INTERVAL}s..." | stdbuf -oL tee -a "$LOG_FILE"
    sleep "$INTERVAL" &
    wait $! || true
  fi
done

echo "[loop] $(date '+%Y-%m-%d %H:%M:%S') - Loop job stopped." | stdbuf -oL tee -a "$LOG_FILE"
