# Quickey

<p align="center">
  <img src="docs/screenshot.png" alt="Quickey" width="600">
</p>

Quickey is a macOS menu bar app that binds global shortcuts to target apps, with Thor-like toggle behavior, fast activation, and lightweight usage insights.

## Highlights
- Global shortcuts that launch or toggle target apps with a single keystroke
- Thor-like semantics that activate, re-activate hidden apps, or directly hide the frontmost target depending on state
- Standard shortcuts use Carbon hotkeys; Hyper shortcuts use the active event tap
- Accurate shortcut readiness reflects Accessibility, Input Monitoring, Carbon registration, and live Hyper event-tap health
- Sparkle-based in-app updates with a manual `Check for Updates…` entry point and automatic background checks/downloads by default
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
./scripts/package-update-zip.sh # Sparkle update ZIP from build/Quickey.app
./scripts/package-dmg.sh        # drag-install DMG from build/Quickey.app
./scripts/e2e-full-test.sh      # end-to-end suite using the current saved shortcuts (Accessibility required; Input Monitoring needed when Hyper shortcuts are configured)
```

## Permissions / First Launch
- Quickey needs `Accessibility` to intercept and route all shortcuts.
- Quickey needs `Input Monitoring` only when the current enabled shortcut set includes Hyper-routed shortcuts.
- Grant permissions in:
  `System Settings > Privacy & Security > Accessibility`
  `System Settings > Privacy & Security > Input Monitoring`
- When testing a newly built `build/Quickey.app`, do not assume an older `/Applications/Quickey.app` grant will carry over. If macOS is still pointing at the wrong app copy, remove the old `Quickey` entry and add the current app bundle again.
- After changing `Input Monitoring`, quit and reopen Quickey so the active event tap is recreated under the new permission state.
- Prefer `open build/Quickey.app` over launching the binary directly so macOS tracks the correct app identity for TCC.
- To confirm the grant actually took effect, inspect `~/.config/Quickey/debug.log`:
  - `ax=true` is the Accessibility signal
  - `im=true` is the Input Monitoring signal
  - `carbon=true` means standard shortcuts registered successfully
  - `eventTap=true` means the Hyper capture path is active

`Launch at Login` should be validated from a packaged app installed in `/Applications` or `~/Applications`. Running `build/Quickey.app` directly from the repo can surface an install-location warning instead of a real login-item configuration state.

Tagged releases use `v<CFBundleShortVersionString>` and are intended to publish:

- `Quickey-<version>.dmg` on GitHub Releases for first install
- `Quickey-<version>.zip` plus `appcast.xml` on Cloudflare R2 for Sparkle in-app updates

The full flow is documented in [`docs/signing-and-release.md`](./docs/signing-and-release.md). Credential-backed release validation and Sparkle runtime validation still require a real macOS environment. The rolling [internal prerelease](https://github.com/xrf9268-hue/Quickey/releases/tag/internal-downloads) remains DMG-only, unsigned, and intended only for trusted testers.

## Documentation
- [`docs/README.md`](./docs/README.md)
- [`docs/architecture.md`](./docs/architecture.md)
- [`docs/github-automation.md`](./docs/github-automation.md)
- [`docs/signing-and-release.md`](./docs/signing-and-release.md)

## Repository Automation
GitHub Actions now enforce PR issue linkage (`Fixes #...`) and keep the `Quickey Backlog` project's `Status` / `Runtime Validation` fields synchronized. See [`docs/github-automation.md`](./docs/github-automation.md) for the required `PROJECT_AUTOMATION_TOKEN` secret and the recommended branch-protection check.
