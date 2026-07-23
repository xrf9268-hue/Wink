---
name: guide-media-pipeline
description: Reproducible pipeline for the /guide demo videos and Settings screenshots — staging a demo config, scripted CGEvent recording, theme/locale screenshot matrix, encoding, R2 upload, and full environment restore. Load before re-recording guide media, refreshing screenshots after a UI change, or adding a locale.
---

# Guide Media Pipeline

Everything at `wink.aixie.de/media/*` (five demo videos, twelve Settings
screenshots) was produced by this pipeline on 2026-07-23. It is fully
scripted so a UI change means re-running it, not re-doing it by hand.

## Hard preconditions

- **The user must be present and must approve the run.** The pipeline
  injects global keystrokes, drives the frontmost app, changes system
  appearance, swaps the wallpaper, and records the screen. The machine
  must be hands-off during recording windows (announce them).
- One display whose current Space is **empty** (the stage). Scripts
  assume it spans `0,0,1920x1080`; adjust the geometry constants if the
  layout changed (`winlist`-style CGWindowList dumps tell you).
- TCC for the terminal host: Accessibility (CGEvent posting + System
  Events UI scripting) and Screen Recording (`screencapture`). Grants
  persist per host app; a first run may prompt.
- `wrangler` OAuth able to write bucket `wink-releases` (no S3 keys
  needed) and `ffmpeg` on PATH.
- Wink installed at `/Applications/Wink.app` — record the SHIPPED build,
  never a dev build.

## Run book

All scripts live in `scripts/` next to this file. Work dir defaults to
`~/.cache/wink-guide-media` (backups live there too — NOT in /tmp).

1. `stage.sh` — backs up `~/Library/Application Support/Wink/` and the
   `com.wink.app` defaults, installs the demo config (⇪S Safari
   toggle+picker · ⇪T Terminal cycle · ⇪N Notes · ⇪Space palette),
   swaps in a synthetic `usage.db`, switches the app to English,
   relaunches Wink, sets the brand wallpaper, pauses PomoFox (noting
   whether it was running), and stages Safari (3 windows, one
   minimized) + Terminal (3 windows, one minimized) on the stage
   display. **Verifies `shortcuts=4
   triggerIndex=4` in `~/.config/Wink/debug.log` before returning.**
2. `record-clips.sh` — records the five clips (~2 min hands-off).
3. Screenshot matrix — for each locale × theme, relaunch/switch then
   `shoot-settings.sh <suffix>`:
   ```
   shoot-settings.sh en-dark          # system dark, app English
   (switch appearance to light)       # osascript System Events
   shoot-settings.sh en-light
   (defaults write com.wink.app AppleLanguages -array zh-Hans; relaunch)
   shoot-settings.sh zh-light
   (switch appearance back to dark)
   shoot-settings.sh zh-dark
   ```
4. **Review every clip and screenshot frame-by-frame for personal
   content before upload.** Extract frames with ffmpeg and look at them.
   Palette queries must resolve to STAGED apps only — a broad query
   surfaces the user's real installed apps (a "term" query once launched
   the user's Termius).
5. `encode-and-upload.sh` — crops/encodes the clips and uploads all
   media to `wink-releases` under `wink/guide/`.
6. `restore.sh <backup-dir>` — restores config, defaults, language,
   wallpaper, PomoFox (only if it was running before staging), quits
   staged apps, relaunches Wink. **Never skip
   this.** Verify the user's shortcut count afterwards (it prints it).
7. Wire any new media into `docs/design/landing/guide.html` and
   `guide-zh.html` (`.fig` figures; videos 1480×1000, screenshots
   860×816 — keep the width/height attributes truthful), run
   `scripts/generate-worker-site.py`, and ship through the normal PR
   flow (`pr-review-loop`).

## Media contract

- Bucket `wink-releases`, key prefix `wink/guide/`, served same-origin
  by the worker at `/media/<basename>` (allow-list: `[a-z0-9-]+\.(mp4|png)`).
- The worker implements single-range 206 responses — Safari refuses
  `<video>` without them. Don't move media to a host that lacks ranges.
- Screenshots ship as light/dark pairs and follow the page theme via
  `.only-light` / `.only-dark`; zh pages use zh screenshots.

## Gotchas (each cost a re-take)

1. **`screencapture -v` never overwrites** — `rm -f` the target first,
   or it records fine and then fails to save.
2. **Sentinel shortcuts need `"target"`** (`"searchPalette"` /
   `"frontmostApp"`) in shortcuts.json, or they are silently dropped
   from the trigger index while the cheat sheet still shows them (#404).
   Space is the string `"space"`, not `" "`.
3. **Synthetic usage.db must carry `PRAGMA user_version = 3`** or Wink
   wipes and re-creates it at launch.
4. **Palette-commit activation doesn't raise the target's windows**
   (#403) — for the palette clip, pre-hide the target so the commit
   visibly springs its windows back.
5. **Settings sidebar tabs**: AX name-matching is unreliable for zh and
   row indices shift; click by coordinates (window pinned at 530,130).
   The Settings window is AX `window "Wink"`; window 1 is the popover.
6. **Headless Chrome's minimum window width is 500** — a "390px"
   screenshot is a cropped 500px viewport, not a layout overflow.
   Measure `document.scrollWidth` before diagnosing.
7. Quit overlay apps before recording (PomoFox's floating timer
   photobombs and its break screen can take over mid-clip); restore
   after. Wallpaper set via System Events needs `killall WallpaperAgent`
   to actually apply.
8. Panels appear on the display hosting the **pointer** — park the
   mouse on the stage display (scripts do this).
9. F19 chords: hold >80 ms, set flags explicitly — see the synthetic
   input rules in `AGENTS.md` history and scripts/e2e-lib.sh lineage.
10. Cycling un-minimizes windows and clip order mutates window state —
    each clip's script re-establishes its own pre-state; don't reorder
    clips without re-checking pre-states.
