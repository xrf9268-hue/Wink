#!/bin/zsh
# Stage the demo environment for guide media recording.
# Backs up the user's Wink state, installs the demo config, dresses the set.
set -eu
HERE="${0:A:h}"
WORK="${WINK_MEDIA_WORK:-$HOME/.cache/wink-guide-media}"
BACKUP="$WORK/backup-$(date +%Y%m%d-%H%M%S)"
APPSUP="$HOME/Library/Application Support/Wink"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
mkdir -p "$WORK" "$BACKUP"

# Refuse to stage over a live user session: step 5 creates and closes
# Safari and Terminal windows, which must never eat real work. Quit them
# yourself, then re-run. (Step 5 additionally aborts — windows untouched —
# if Resume hands the launch a saved session; running is not the only way
# real windows can be present.)
for app in Safari Terminal; do
  if pgrep -xq "$app"; then
    echo "ABORT: $app is running — quit it first, then re-run stage.sh" >&2
    exit 1
  fi
done

# 0. tools
if [ ! -x "$WORK/winkkeys" ]; then
  swiftc -O "$HERE/winkkeys.swift" -o "$WORK/winkkeys"
fi

# 1. backup (config dir + defaults). restore.sh needs this directory.
cp -a "$APPSUP/" "$BACKUP/AppSupport/"
defaults export com.wink.app "$BACKUP/com.wink.app.plist"
defaults read -g AppleInterfaceStyle > "$BACKUP/appearance.txt" 2>/dev/null || echo Light > "$BACKUP/appearance.txt"
# record current wallpapers, one path per desktop line, for restore.sh
osascript > "$BACKUP/wallpapers.txt" 2>/dev/null <<'EOS' || true
set out to ""
tell application "System Events"
  repeat with d in desktops
    set out to out & (picture of d) & linefeed
  end repeat
end tell
return out
EOS
# Notes is launched mid-recording by the ⇪N demo chord; record whether
# it was already running so restore.sh can tell demo cleanup from
# session damage when it quits Notes
pgrep -xq Notes && touch "$BACKUP/notes-was-running" || true
echo "backup: $BACKUP"

# 2. demo config + synthetic usage, app in English
pkill -x Wink || true; sleep 0.6
cp "$HERE/demo-shortcuts.json" "$APPSUP/shortcuts.json"
python3 "$HERE/make-demo-usage.py" "$WORK/demo-usage.db"
cp "$WORK/demo-usage.db" "$APPSUP/usage.db"
defaults write com.wink.app AppleLanguages -array en
# Pin EVERY setting the shoot depends on instead of inheriting the user's
# profile — the whole-domain defaults backup restores their real values:
# - hyperKeyEnabled: the demo chords are F19-driven through the
#   interception tap; a Hyper-off profile routes them via Carbon and every
#   injected chord is inert while the count gate still passes.
# - hyperCheatSheetEnabled: the cheat-sheet clip records nothing if the
#   user turned the sheet off.
# - suggestShortcutsFromUsage: the Insights screenshot's Suggested card
#   renders only when the toggle is on (and seeding app_activations is
#   pointless otherwise).
# - menuBarIconVisible: shoot-settings.sh opens Settings through the menu
#   bar item; a hidden icon breaks the whole screenshot matrix.
# - shortcutsPaused / frontmostExceptionsEnabled: a paused profile or an
#   exception rule matching a staged app would silently disarm the demos.
defaults write com.wink.app hyperKeyEnabled -bool true
defaults write com.wink.app hyperCheatSheetEnabled -bool true
defaults write com.wink.app suggestShortcutsFromUsage -bool true
defaults write com.wink.app menuBarIconVisible -bool true
defaults write com.wink.app shortcutsPaused -bool false
defaults write com.wink.app frontmostExceptionsEnabled -bool false
open -a /Applications/Wink.app; sleep 1.5

# 3. verify the trigger index took all four entries (gotcha #2)
"$WORK/winkkeys" chord 45 150 >/dev/null; sleep 0.5   # ⇪N — forces an attemptStart line
"$WORK/winkkeys" chord 45 150 >/dev/null; sleep 0.3   # toggle Notes back off
line=$(grep attemptStart "$HOME/.config/Wink/debug.log" | tail -1)
# Gate on BOTH the index count and a live interception tap: eventTap=false
# (Input Monitoring missing, tap failed) records perfectly inert clips
# while the counts still look right.
case "$line" in
  *"shortcuts=4"*"triggerIndex=4"*"eventTap=true"*) echo "trigger index + event tap OK" ;;
  *) echo "STAGING GATE FAILED (need shortcuts=4 triggerIndex=4 eventTap=true): $line" >&2; exit 1 ;;
esac

# 4. set dressing: brand wallpaper, no overlay apps
if [ -x "$CHROME" ]; then
  "$CHROME" --headless=new --disable-gpu --screenshot="$WORK/wink-wallpaper.png" \
    --window-size=1920,1080 --hide-scrollbars "file://$HERE/wallpaper.html" 2>/dev/null
  osascript -e "tell application \"System Events\" to set picture of every desktop to POSIX file \"$WORK/wink-wallpaper.png\""
  killall WallpaperAgent 2>/dev/null || true
fi
# record whether PomoFox was running before pausing it — restore.sh must
# not hand back a session with an app the user never had open
if pgrep -xq PomoFox; then
  touch "$BACKUP/pomofox-was-running"
  pkill -x PomoFox 2>/dev/null || true
  echo "PomoFox paused for the shoot"
fi

# 5. stage Safari (3 windows, one minimized) and Terminal (3, one minimized).
# The preflight only proves neither app is RUNNING — Resume (or Safari's
# "opens with: All windows from last session") can hand `launch` the
# user's saved session as live windows. Never close a window carrying
# real content: quit the app untouched instead (quit re-saves the session
# losslessly) and abort.
if ! osascript <<'EOF'
tell application "Safari"
  launch
  delay 1.5
  repeat with w in (get every window)
    repeat with t in (get every tab of w)
      set u to URL of t
      if u is not missing value and u is not "" and u is not "favorites://" then
        error "session window restored at launch"
      end if
    end repeat
  end repeat
  close every window
  make new document with properties {URL:"https://wink.aixie.de"}
  delay 1
  make new document with properties {URL:"https://wink.aixie.de/guide"}
  delay 1
  make new document with properties {URL:"https://github.com/xrf9268-hue/Wink"}
  delay 2
  set bounds of window 3 to {320, 120, 1600, 960}
  set bounds of window 2 to {360, 160, 1640, 1000}
  set bounds of window 1 to {400, 200, 1680, 1040}
  set miniaturized of window 3 to true
end tell
EOF
then
  osascript -e 'tell application "Safari" to quit' 2>/dev/null || true
  echo "ABORT: Safari restored a saved session at launch — staging would destroy it." >&2
  echo "Safari was quit with those windows intact. Close them in Safari yourself (or" >&2
  echo "set Safari opens with 'A new window'), quit it again, then re-run stage.sh." >&2
  exit 1
fi
# Terminal opens at most one fresh shell window on a plain launch; more
# than one window at this point means Resume brought saved sessions back.
if ! osascript <<'EOF'
tell application "Terminal"
  launch
  delay 1
  if (count of windows) > 1 then error "saved windows restored at launch"
  close every window
  delay 0.5
  do script ""
  delay 0.5
  do script ""
  delay 0.5
  do script ""
  delay 1
  set custom title of window 3 to "api — zsh"
  set custom title of window 2 to "build — watch"
  set custom title of window 1 to "deploy — ssh"
  set bounds of window 3 to {380, 180, 1450, 780}
  set bounds of window 2 to {430, 230, 1500, 830}
  set bounds of window 1 to {480, 280, 1550, 880}
  set miniaturized of window 3 to true
end tell
EOF
then
  osascript -e 'tell application "Terminal" to quit' 2>/dev/null || true
  echo "ABORT: Terminal restored saved windows at launch — staging would destroy" >&2
  echo "their scrollback. Terminal was quit with them intact. Close them yourself," >&2
  echo "quit it again, then re-run stage.sh." >&2
  exit 1
fi
echo "STAGED — record with record-clips.sh, restore with restore.sh $BACKUP"
