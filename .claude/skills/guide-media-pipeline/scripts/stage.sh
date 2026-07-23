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

# 0. tools
if [ ! -x "$WORK/winkkeys" ]; then
  swiftc -O "$HERE/winkkeys.swift" -o "$WORK/winkkeys"
fi

# 1. backup (config dir + defaults). restore.sh needs this directory.
cp -a "$APPSUP/" "$BACKUP/AppSupport/"
defaults export com.wink.app "$BACKUP/com.wink.app.plist"
defaults read -g AppleInterfaceStyle > "$BACKUP/appearance.txt" 2>/dev/null || echo Light > "$BACKUP/appearance.txt"
echo "backup: $BACKUP"

# 2. demo config + synthetic usage, app in English
pkill -x Wink || true; sleep 0.6
cp "$HERE/demo-shortcuts.json" "$APPSUP/shortcuts.json"
python3 "$HERE/make-demo-usage.py" "$WORK/demo-usage.db"
cp "$WORK/demo-usage.db" "$APPSUP/usage.db"
defaults write com.wink.app AppleLanguages -array en
open -a /Applications/Wink.app; sleep 1.5

# 3. verify the trigger index took all four entries (gotcha #2)
"$WORK/winkkeys" chord 45 150 >/dev/null; sleep 0.5   # ⇪N — forces an attemptStart line
"$WORK/winkkeys" chord 45 150 >/dev/null; sleep 0.3   # toggle Notes back off
line=$(grep attemptStart "$HOME/.config/Wink/debug.log" | tail -1)
case "$line" in
  *"shortcuts=4"*"triggerIndex=4"*) echo "trigger index OK" ;;
  *) echo "TRIGGER INDEX MISMATCH: $line" >&2; exit 1 ;;
esac

# 4. set dressing: brand wallpaper, no overlay apps
if [ -x "$CHROME" ]; then
  "$CHROME" --headless=new --disable-gpu --screenshot="$WORK/wink-wallpaper.png" \
    --window-size=1920,1080 --hide-scrollbars "file://$HERE/wallpaper.html" 2>/dev/null
  osascript -e "tell application \"System Events\" to set picture of every desktop to POSIX file \"$WORK/wink-wallpaper.png\""
  killall WallpaperAgent 2>/dev/null || true
fi
pkill -x PomoFox 2>/dev/null && echo "PomoFox paused for the shoot" || true

# 5. stage Safari (3 windows, one minimized) and Terminal (3, one minimized)
osascript <<'EOF'
tell application "Safari"
  launch
  delay 1
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
tell application "Terminal"
  launch
  delay 1
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
echo "STAGED — record with record-clips.sh, restore with restore.sh $BACKUP"
