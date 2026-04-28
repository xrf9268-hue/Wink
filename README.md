# Wink

<p align="center">
  <img src="docs/screenshot.png" alt="Wink settings showing shortcut capture ready" width="720">
</p>

Wink is a macOS menu bar app for opening, focusing, and hiding apps with global shortcuts. It keeps the interaction deliberately small: press a shortcut once to bring an app forward, press it again to get it out of the way.

## Why "Wink"?
Wink suggests a quick, subtle signal: something that happens almost instantly and then gets out of the way. That is the feeling Wink aims for when switching apps.

## Highlights
- Bind letters, function keys, arrows, or Space to target apps.
- Use normal modifier shortcuts or a Hyper shortcut path based on Caps Lock.
- Launch missing apps, focus running apps, or hide the frontmost target with Thor-like toggle semantics.
- Review shortcuts, readiness, and recent usage from the menu bar and Settings.
- Import and export `.winkrecipe` shortcut sets.
- Launch at login and automatic updates are surfaced through native macOS controls.

## Requirements
- macOS 15 or later.
- Accessibility permission for global shortcut routing.
- Input Monitoring only when Hyper-routed shortcuts are enabled.
- Swift 6 when building from source.

## Build
```bash
swift build
swift test
./scripts/package-app.sh
open build/Wink.app
```

Useful packaging commands:

```bash
./scripts/package-update-zip.sh
./scripts/package-dmg.sh
./scripts/e2e-full-test.sh
```

Always launch the packaged app with `open build/Wink.app` when testing permissions. macOS ties Accessibility and Input Monitoring grants to the app identity, signature, and bundle path; launching the raw binary is not equivalent.

## Technical Notes
- Standard shortcuts use Carbon hotkeys.
- Hyper-routed shortcuts use an active event tap.
- Reliable activation for an accessory app depends on SkyLight, a private macOS API. See [`docs/architecture.md`](./docs/architecture.md) for the platform trade-offs.
- Runtime-sensitive behavior must be validated on macOS, not inferred from source inspection alone.

## Documentation
- [`docs/README.md`](./docs/README.md)
- [`docs/architecture.md`](./docs/architecture.md)
- [`docs/github-automation.md`](./docs/github-automation.md)
- [`docs/privacy.md`](./docs/privacy.md)
- [`docs/signing-and-release.md`](./docs/signing-and-release.md)
