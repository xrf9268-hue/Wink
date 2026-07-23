# Changelog

Newest first. One `## X.Y.Z` section per release, written by hand **before** running
`scripts/bump-version.sh X.Y.Z`. `scripts/release-notes.sh X.Y.Z` extracts a section as the
GitHub Release body; the release workflow fails if the tagged version has no section here.

## 0.7.1

Three sharp edges off the window-switching release.

- **Palette switches land in front** — committing the search palette on an
  app whose windows sat behind another app's activated it without raising
  anything: the menu bar said Safari, the screen still showed Terminal.
  Every activation now orders the target's first real content window key
  and front (auxiliary elements like Split View dividers are never
  touched), so the window you asked for is the window you see.
- **Hand-written configs can't half-arm** — a shortcuts.json or .winkrecipe
  entry naming a sentinel target (Search Palette, Current App) without the
  explicit "target" field used to render everywhere and fire nowhere. The
  unambiguous sentinel now backfills; unknown or malformed target values
  stay safely disarmed — and stay that way across every save, load,
  export, and import. The cheat sheet now shows exactly the chords that
  can fire: duplicate-chord losers and uninstalled apps are excluded.
- **Badges keep their shape** — the Search Palette row's HYPER and
  key-combo badges no longer wrap mid-token under tight layouts
  ("⌃⌥⇧⌘SPAC / E").

## 0.7.0

The window-switching release: cycle through an app's windows, search-to-switch
anything, and see every shortcut at a glance.

- **Cycle Windows** — a new "when target is frontmost" behavior: repeat
  presses rotate through the app's windows, minimized ones included, with a
  small HUD showing your position ("2/5 · window title") on the window's own
  display. Set it globally in General, or per shortcut from a row's ⋯ menu.
  Rapid presses feel immediate; single-window apps keep plain toggling.
- **Current App target** — a pinned entry in the app picker that acts on
  whatever app is frontmost, so one chord cycles any app's windows without a
  dedicated binding. A single-window frontmost app stays put — it is never
  hidden by accident.
- **Search to switch** — a palette summoned by its own trigger shortcut:
  type a few letters of any app's name (localized names match too, 微信 finds
  WeChat), hit ⏎, and Wink takes you there — launching the app if it isn't
  running. Recent switches float to the top, and background agents or helper
  processes never clutter the list.
- **Hold to pick a window** — opt any shortcut into a hold action: tap to
  toggle as always, hold the chord to get that app's window list with
  arrow-key navigation and Enter to focus, minimized windows marked.
- **Hyper cheat sheet** — hold Caps Lock with no second key and every bound
  shortcut fades in on the display you're working on; release and it's gone.
- **Per-app exception rules** — shortcuts pause themselves while a VM or
  remote-desktop app is frontmost (the menu bar pill shows "Paused · App")
  and resume when you leave. While paused — by rule or by hand — Caps Lock
  reverts fully to its native behavior, light and all.
- **Secure Input, surfaced** — when a password field engages macOS Secure
  Input, the pill shows "Limited · Secure Input" instead of a false Ready,
  and standard non-Fn shortcuts keep working through it.
- **Scriptable via wink://** — `wink://toggle?bundle=…`, `wink://pause`, and
  `wink://resume` for launchers, Raycast scripts, and automations.
- **简体中文** — the entire app is localized, and macOS can now run Wink in
  Chinese per app from System Settings → General → Language & Region.
- **Insights suggests shortcuts** — apps you switch to often but never bound
  show up with their switch counts, one click away from a new shortcut. The
  Insights page also got a scrollable layout so no card is ever cut off.
- **Wink amber** — a refreshed accent color and an ink-navy app icon across
  the app.

## 0.6.2

Shortcut reliability fixes, preserved usage history, and fresher stats.

- **Fn shortcuts fire again** — bindings that use the Fn key were registered
  without the Fn modifier, so they could stay silent or trigger on the bare
  key instead.
- **Shortcut capture recovers cleanly after interruptions** — a system
  timeout, a permission change, or a failed re-registration could leave
  capture half-active while Settings still reported it as ready. Those paths
  now restore fully, retry only what is missing, and report their real state.
- **Toggling off waits for real evidence** — when macOS cannot tell Wink
  whether a target app still has windows, Wink no longer treats that silence
  as proof the app was hidden, and an app that stops responding can no longer
  stall the keypress path.
- **Usage history survives a language change** — under Arabic and Persian
  system languages Wink recorded dates in localized digits, which made past
  activity disappear from Insights. Existing history is converted
  automatically the first time you open this version.
- **Settings explains a failed Launch at Login** — the switch used to snap
  back with no message; it now says what went wrong and offers to open Login
  Items.
- **Fresher, faster stats** — Insights and the Shortcuts list update when you
  come back to Wink, and "Last used" no longer slows down as usage history
  grows.
- **Damaged shortcut files are refused, not silently loaded** — a file
  containing duplicate shortcut entries is now rejected and preserved for
  inspection instead of being partially applied.

## 0.6.1

Accessibility, a false-positive warning fix, and interface polish.

- **"Couldn't find its login item configuration" was a false alarm** — Settings
  no longer shows this as a packaging error the first time Wink sees a
  correctly installed copy; the warning now only appears if turning Launch at
  Login on actually fails.
- **Traffic lights work with VoiceOver and keyboard-only navigation again** —
  closing, minimizing, and zooming the Settings window via assistive
  technology was silently broken since the titlebar realignment in 0.6.0.
- **Interface polish across Settings and the menu bar** — corrected colors,
  spacing, and typography against the design system in the Shortcuts,
  Insights, and General tabs and the menu bar popover, including a clearer
  usage heatmap and a fixed keyboard-navigation bug when choosing a target
  app.

## 0.6.0

In-app updates and interface polish.

- **Updates now live inside Wink** — checking, download progress, and
  install/relaunch happen in a native Wink panel instead of separate Sparkle
  dialogs. Scheduled checks stay quiet: a new version appears as a menu bar
  notice and in Settings, never as a surprise popup.
- **The Automatic Updates switch is real** — turn background update checks
  and downloads on or off from Settings → General, which also shows live
  update status and when Wink last checked.
- **What's New after updating** — a one-time panel summarizes the highlights
  after an update installs.
- **Snappier shortcuts** — redundant window queries and scheduling hops were
  removed from the keypress-to-activation path, including when restoring
  minimized windows.
- **Settings titlebar aligned** — the traffic lights, sidebar toggle, and
  window title finally share one centerline.

## 0.5.0

First public release.

- **Toggle apps with global shortcuts** — press once to open or focus the target
  app, press again to hide it. Letters, function keys, arrows, and Space can all
  be bound.
- **Two shortcut paths** — normal modifier combos (Carbon hotkeys) or a Hyper
  path driven by Caps Lock (event tap).
- **Menu bar native** — review shortcuts, permission readiness, and recent usage
  from the menu bar and Settings; launch at login and automatic updates use
  native macOS controls.
- **Shareable shortcut sets** — import and export `.winkrecipe` files.
- **Insights** — recent usage trends surfaced in Settings.

Requires macOS 15+, Accessibility permission for shortcut routing, and Input
Monitoring only when Hyper-routed shortcuts are enabled.

## 0.4.1

- Baseline entry: current version at the time the changelog was introduced. No `v*` release
  has been published yet; the first published release gets a full section.
