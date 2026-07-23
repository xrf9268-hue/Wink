#!/bin/zsh
# Capture the three Settings tabs. Usage: shoot-settings.sh <suffix>
# (e.g. en-dark). Caller controls app language and system appearance:
#   defaults write com.wink.app AppleLanguages -array zh-Hans && relaunch Wink
#   osascript -e 'tell app "System Events" to tell appearance preferences to set dark mode to false'
# Tabs are clicked by COORDINATES (window pinned at 530,130) because AX
# name-matching is unreliable for zh and row indices shift (gotcha #5).
set -u
SUF="$1"
WORK="${WINK_MEDIA_WORK:-$HOME/.cache/wink-guide-media}"
OUT="$WORK/shots"
mkdir -p "$OUT"

osascript -e 'tell application "System Events" to tell process "Wink" to click menu bar item 1 of menu bar 2' >/dev/null
sleep 1
osascript -e 'tell application "System Events" to tell process "Wink" to click button 2 of group 1 of window 1' >/dev/null
sleep 1.2
osascript -e 'tell application "System Events" to tell process "Wink"
  set position of window "Wink" to {530, 130}
end tell' >/dev/null
sleep 0.4

winid=$(python3 -c "
import Quartz
wins = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID)
for w in wins:
    if w.get('kCGWindowOwnerName') == 'Wink' and w.get('kCGWindowLayer') == 0 and w['kCGWindowBounds']['Width'] > 500:
        print(w.get('kCGWindowNumber')); break")
if [ -z "$winid" ]; then echo "NO SETTINGS WINDOW"; exit 1; fi

click_row() { # $1 = global y (sidebar x=620; rows: 200 Shortcuts / 228 Insights / 256 General)
  python3 -c "
import Quartz, time
def ev(t, pos):
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, Quartz.CGEventCreateMouseEvent(None, t, pos, 0))
p = (620, $1)
ev(Quartz.kCGEventMouseMoved, p); time.sleep(0.1)
ev(Quartz.kCGEventLeftMouseDown, p); time.sleep(0.05)
ev(Quartz.kCGEventLeftMouseUp, p)"
  sleep 0.9
}

click_row 256; screencapture -x -o -l"$winid" "$OUT/settings-general-$SUF.png"
click_row 200; screencapture -x -o -l"$winid" "$OUT/settings-shortcuts-$SUF.png"
click_row 228; screencapture -x -o -l"$winid" "$OUT/settings-insights-$SUF.png"

echo "SHOTS_DONE_$SUF"
