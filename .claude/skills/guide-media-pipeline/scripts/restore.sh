#!/bin/zsh
# Restore the user's environment after a shoot. Usage: restore.sh <backup-dir>
# (the directory stage.sh printed). NEVER skip this step.
set -eu
BACKUP="$1"
APPSUP="$HOME/Library/Application Support/Wink"
[ -d "$BACKUP/AppSupport" ] || { echo "not a stage.sh backup: $BACKUP" >&2; exit 1; }

pkill -x Wink || true; sleep 0.6
# put back exactly what stage.sh backed up: a file absent from the
# backup must be absent after the restore too. A fresh profile
# legitimately lacks shortcuts.json (PersistenceService.load() treats a
# missing file as an empty configuration) — the demo copy must not
# outlive the shoot, and an unconditional cp would abort the whole
# restore under set -e before defaults/wallpaper are put back
for f in shortcuts.json usage.db recent-apps.json; do
  if [ -f "$BACKUP/AppSupport/$f" ]; then
    cp "$BACKUP/AppSupport/$f" "$APPSUP/"
  else
    rm -f "$APPSUP/$f"
  fi
done

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
# reopen PomoFox only if stage.sh actually paused it: a full restore
# must not add apps to a session that never had them
if [ -f "$BACKUP/pomofox-was-running" ]; then
  open -g -a PomoFox 2>/dev/null || true
fi
osascript -e 'tell application "Safari" to quit' 2>/dev/null || true
osascript -e 'tell application "Terminal" to quit' 2>/dev/null || true
# Notes was only launched by the ⇪N demo chord — quit it unless the
# user already had it running before staging (Safari/Terminal need no
# marker: stage.sh refuses to run while they are open)
if [ ! -f "$BACKUP/notes-was-running" ]; then
  osascript -e 'tell application "Notes" to quit' 2>/dev/null || true
fi

if [ -f "$APPSUP/shortcuts.json" ]; then
  count=$(python3 -c "import json;print(len(json.load(open('$APPSUP/shortcuts.json'))))")
  echo "RESTORED — $count user shortcuts back in place (verify this matches expectations)"
else
  echo "RESTORED — shortcutless profile preserved (no shortcuts.json, same as before staging)"
fi
