#!/usr/bin/env bash
SESSION="quickey-loop"
REPO="$HOME/developer/Quickey"

if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "Stopping existing session..."
  tmux kill-session -t "$SESSION"
fi

tmux new-session -d -s "$SESSION" -c "$REPO"
tmux send-keys -t "$SESSION" "bash \"$REPO/scripts/run-loop.sh\"" Enter

echo "Loop job started in tmux session: $SESSION"
echo "Attach with: tmux attach -t $SESSION"
