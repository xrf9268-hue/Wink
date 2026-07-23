#!/bin/zsh
# Record the five guide demo clips on the stage display (0,0,1920x1080).
# Requires stage.sh to have run. ~2 minutes; the machine must be hands-off.
set -eu
WORK="${WINK_MEDIA_WORK:-$HOME/.cache/wink-guide-media}"
K="$WORK/winkkeys"
R="$WORK/rec"
mkdir -p "$R"

park_mouse() {
  python3 -c "
import Quartz
ev = Quartz.CGEventCreateMouseEvent(None, Quartz.kCGEventMouseMoved, (80, 1040), 0)
Quartz.CGEventPost(Quartz.kCGHIDEventTap, ev)"
}

front() { osascript -e "tell application \"$1\" to activate" >/dev/null 2>&1; }

record() { # $1=name $2=seconds — screencapture never overwrites (gotcha #1)
  rm -f "$R/$1.mov"
  screencapture -v -V "$2" -R 0,0,1920,1080 "$R/$1.mov" &
  CAP=$!
  sleep 2.0
}

# wait propagates screencapture's exit status, so a failed recording
# (Screen Recording revoked, disk full) aborts here under set -e instead
# of silently reporting ALL_CLIPS_DONE; the size check catches an exit-0
# capture that still wrote nothing
finish() {
  if ! wait $CAP 2>/dev/null; then
    echo "CAPTURE FAILED (screencapture exit nonzero): $1" >&2; exit 1
  fi
  [ -s "$R/$1.mov" ] || { echo "CAPTURE FAILED (empty/missing): $1" >&2; exit 1; }
  echo "clip done: $1"
}

# ---------- A: first chord (Safari summon / dismiss / summon) ----------
front Terminal; sleep 1.2; park_mouse
record clip-first-chord 13
"$K" chord 1 150;  sleep 2.2
"$K" chord 1 150;  sleep 2.2
"$K" chord 1 150;  sleep 2.0
finish clip-first-chord

# ---------- B: cycle Terminal windows (incl. minimized) ----------
front Terminal; sleep 1.2; park_mouse
record clip-cycle 13
"$K" chord 17 150; sleep 1.8
"$K" chord 17 150; sleep 1.8
"$K" chord 17 150; sleep 1.8
"$K" chord 17 150; sleep 2.0
finish clip-cycle

# ---------- C: hold to pick a window (Safari picker) ----------
front Terminal; sleep 1.2; park_mouse
record clip-picker 15
"$K" chord 1 1300; sleep 1.6   # hold past threshold; picker stays after release
"$K" key 125;      sleep 0.9
"$K" key 125;      sleep 0.9
"$K" key 36;       sleep 2.2
finish clip-picker

# ---------- D: search palette (pre-hide Safari — #403 workaround) ----------
front Terminal; sleep 1.0
"$K" chord 1 150; sleep 1.2   # summon
"$K" chord 1 150; sleep 1.0   # hide — commit will visibly spring it back
front Terminal; sleep 0.8; park_mouse
record clip-palette 12
"$K" chord 49 150; sleep 1.4
"$K" type safa;    sleep 1.6   # staged app ONLY — broad queries surface real apps
"$K" key 36;       sleep 2.5
finish clip-palette

# ---------- E: cheat sheet (hold Hyper alone) ----------
front Terminal; sleep 1.2; park_mouse
record clip-cheatsheet 9
"$K" f19 2600;     sleep 1.6
finish clip-cheatsheet

ls -la "$R"
echo ALL_CLIPS_DONE
