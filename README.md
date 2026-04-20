# Wink

<p align="center">
  <img src="docs/screenshot.png" alt="Wink" width="600">
</p>

Wink is a macOS menu bar app that binds global shortcuts to target apps, with Thor-like toggle behavior, fast activation, and lightweight usage insights.

## Why "Wink"?
The rename from `Quickey` to `Wink` came out of [issue #183](https://github.com/xrf9268-hue/Wink/issues/183): the old name explained the mechanism ("quick keys"), while the new name tries to capture the feeling. The goal is app switching that happens "in the wink of an eye" rather than a tool name that only describes hotkeys.

- It emphasizes the experience: fast, almost instant switching
- It keeps the product short, lightweight, and a little more human than a purely functional utility name
- It mirrors the same naming instinct that inspired tools like [Shun](https://blog.sorrycc.com/release-shun): name the sensation, not just the implementation

## Highlights
- Global shortcuts that launch or toggle target apps with a single keystroke
- Thor-like semantics that activate, re-activate hidden apps, or directly hide the frontmost target depending on state
- Standard shortcuts use Carbon hotkeys; Hyper shortcuts use the active event tap
- Accurate shortcut readiness reflects Accessibility, Input Monitoring, Carbon registration, and live Hyper event-tap health
- Supports letters, modifiers, Hyper Key, F-keys, arrows, and space
- Launch at login support with system approval surfaced in the app
- Insights view for recent usage trends and app ranking
- Swift 6, AppKit-first, and SPM-first by design

## Requirements and Constraints
- macOS 15+
- Swift 6 / SPM-first
- macOS runtime behavior must be validated on macOS
- SkyLight is a private API dependency for activation reliability

## Build and Run
```bash
swift build
swift test
./scripts/package-app.sh        # release build + .app bundle
./scripts/package-dmg.sh        # drag-install DMG from build/Wink.app
./scripts/e2e-full-test.sh      # end-to-end suite using the current saved shortcuts (Accessibility required; Input Monitoring needed when Hyper shortcuts are configured)
```

## Permissions / First Launch
- Wink needs `Accessibility` to intercept and route all shortcuts.
- Wink needs `Input Monitoring` only when the current enabled shortcut set includes Hyper-routed shortcuts.
- Grant permissions in:
  `System Settings > Privacy & Security > Accessibility`
  `System Settings > Privacy & Security > Input Monitoring`
- When testing a newly built `build/Wink.app`, do not assume an older `/Applications/Wink.app` grant will carry over. If macOS is still pointing at the wrong app copy, remove the old `Wink` entry and add the current app bundle again.
- After changing `Input Monitoring`, quit and reopen Wink so the active event tap is recreated under the new permission state.
- Prefer `open build/Wink.app` over launching the binary directly so macOS tracks the correct app identity for TCC.
- To confirm the grant actually took effect, inspect `~/.config/Wink/debug.log`:
  - `ax=true` is the Accessibility signal
  - `im=true` is the Input Monitoring signal
  - `carbon=true` means standard shortcuts registered successfully
  - `eventTap=true` means the Hyper capture path is active

`Launch at Login` should be validated from a packaged app installed in `/Applications` or `~/Applications`. Running `build/Wink.app` directly from the repo can surface an install-location warning instead of a real login-item configuration state.

Tagged releases use `v<CFBundleShortVersionString>` and publish `Wink-<version>.dmg` through the release workflow described in [`docs/signing-and-release.md`](./docs/signing-and-release.md). Notarized releases are not yet available; the current [internal prerelease](https://github.com/xrf9268-hue/Wink/releases/tag/internal-downloads) is unsigned, so macOS may warn on first launch.

## Documentation
- [`docs/README.md`](./docs/README.md)
- [`docs/architecture.md`](./docs/architecture.md)
- [`docs/github-automation.md`](./docs/github-automation.md)
- [`docs/signing-and-release.md`](./docs/signing-and-release.md)

## Repository Automation
GitHub Actions now enforce PR issue linkage (`Fixes #...`) and keep the `Wink Backlog` project's `Status` / `Runtime Validation` fields synchronized. See [`docs/github-automation.md`](./docs/github-automation.md) for the required `PROJECT_AUTOMATION_TOKEN` secret and the recommended branch-protection check.
