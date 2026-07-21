# Changelog

Newest first. One `## X.Y.Z` section per release, written by hand **before** running
`scripts/bump-version.sh X.Y.Z`. `scripts/release-notes.sh X.Y.Z` extracts a section as the
GitHub Release body; the release workflow fails if the tagged version has no section here.

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
