# Changelog

Newest first. One `## X.Y.Z` section per release, written by hand **before** running
`scripts/bump-version.sh X.Y.Z`. `scripts/release-notes.sh X.Y.Z` extracts a section as the
GitHub Release body; the release workflow fails if the tagged version has no section here.

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
