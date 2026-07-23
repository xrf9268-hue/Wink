#!/bin/zsh
# Restore the user's environment after a shoot. Usage: restore.sh <backup-dir>
# (the directory stage.sh printed). NEVER skip this step.
set -eu
BACKUP="$1"
APPSUP="$HOME/Library/Application Support/Wink"
[ -d "$BACKUP/AppSupport" ] || { echo "not a stage.sh backup: $BACKUP" >&2; exit 1; }

pkill -x Wink || true; sleep 0.6
cp "$BACKUP/AppSupport/shortcuts.json" "$BACKUP/AppSupport/usage.db" "$APPSUP/"
# restore recent-apps.json's absence too: if the user never had one, a
# file the demo session created must not survive the restore
if [ -f "$BACKUP/AppSupport/recent-apps.json" ]; then
  cp "$BACKUP/AppSupport/recent-apps.json" "$APPSUP/"
else
  rm -f "$APPSUP/recent-apps.json"
fi

# restore the ENTIRE defaults domain from the backup export — the shoot
# touches more than AppleLanguages (and future stagings may touch more
# still); delete-then-import puts back exactly what stage.sh saved
defaults delete com.wink.app 2>/dev/null || true
defaults import com.wink.app "$BACKUP/com.wink.app.plist"

open -a /Applications/Wink.app; sleep 1

# restore the wallpapers stage.sh recorded (one path per desktop line);
# fall back to the system default only if nothing was recorded
if [ -s "$BACKUP/wallpapers.txt" ]; then
  i=1
  while IFS= read -r wp; do
    if [ -n "$wp" ] && [ -e "$wp" ]; then
      osascript -e "tell application \"System Events\" to set picture of desktop $i to POSIX file \"$wp\"" 2>/dev/null || true
    fi
    i=$((i + 1))
  done < "$BACKUP/wallpapers.txt"
else
  osascript -e 'tell application "System Events" to set picture of every desktop to POSIX file "/System/Library/CoreServices/DefaultDesktop.heic"' || true
fi
killall WallpaperAgent 2>/dev/null || true
if [ "$(cat "$BACKUP/appearance.txt" 2>/dev/null)" = "Dark" ]; then
  osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to true' || true
else
  osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to false' || true
fi
open -g -a PomoFox 2>/dev/null || true
osascript -e 'tell application "Safari" to quit' 2>/dev/null || true
osascript -e 'tell application "Terminal" to quit' 2>/dev/null || true
osascript -e 'tell application "Notes" to quit' 2>/dev/null || true

count=$(python3 -c "import json;print(len(json.load(open('$APPSUP/shortcuts.json'))))")
echo "RESTORED — $count user shortcuts back in place (verify this matches expectations)"
