# Sparkle Auto Update Design

**Date:** 2026-04-18
**Branch:** `issue-175-sparkle-auto-update`
**Issue:** `#175` Sparkle 自动更新支持
**Scope:** Add Sparkle-based automatic updates to Quickey, including app-side integration, Sparkle-compatible packaging, Cloudflare R2 appcast hosting, and release automation while preserving the existing DMG-first install path

## Overview

Quickey currently ships through a signed and notarized DMG published on GitHub Releases. That works for first-time installation, but every upgrade still requires the user to manually discover, download, and replace the app.

This design adds Sparkle as a dedicated update subsystem without reworking Quickey's existing menu bar architecture. Initial downloads continue to use the current DMG release path, while in-app updates use Sparkle's `ZIP + appcast.xml` model hosted on Cloudflare R2. The result is a dual-track distribution model:

- GitHub Releases DMG for first install and manual download
- Sparkle ZIP + appcast on R2 for in-app update checks and installs

The design keeps `scripts/package-app.sh` as the single packaged `.app` source of truth, introduces a small app-facing update service boundary, and extends release automation so a single tagged release produces both the DMG and Sparkle update metadata.

## Goals

- Add a stable Sparkle updater to Quickey's app lifecycle without leaking Sparkle types through the SwiftUI layer
- Add a `Check for Updates…` entry point in the General settings tab
- Default to automatic update checks plus automatic background downloads
- Package `Quickey.app` in a Sparkle-compatible way, including framework embedding, rpath configuration, and code signing
- Publish Sparkle update ZIPs and `appcast.xml` to Cloudflare R2
- Preserve the current signed/notarized DMG GitHub Release flow for first installs
- Keep ordinary CI credential-free while making the tag-driven release workflow fail closed
- Document the macOS-only validation that remains mandatory after implementation

## Non-Goals

- Replacing the DMG as Quickey's primary first-install artifact
- Building a custom Sparkle UI or custom release-notes renderer
- Adding staged rollouts, beta channels, or signed appcasts
- Claiming runtime correctness from Linux-only inspection
- Introducing an installer package, Sparkle delta customizations, or a release management backend

## Current Context

- Quickey is a SwiftPM-first macOS menu bar app packaged by `scripts/package-app.sh`
- `scripts/package-app.sh` currently assembles `build/Quickey.app` manually and signs it as a single bundle
- `scripts/package-dmg.sh` wraps the packaged app into `build/Quickey-<version>.dmg`
- `.github/workflows/ci.yml` verifies build, tests, app packaging, and DMG packaging on `macos-15`
- `.github/workflows/release.yml` signs, notarizes, staples, validates, and publishes only the DMG to GitHub Releases
- `.github/workflows/internal-package.yml` publishes an unsigned internal DMG prerelease for trusted testers
- `GeneralTabView` already contains settings controls such as Launch at Login and Hyper Key, making it the right surface for a manual update action
- Quickey is not sandboxed, so Sparkle's sandbox-only service requirements do not apply

## Approved Product Decisions

| Topic | Decision |
|------|----------|
| First-install distribution | Keep signed/notarized DMG on GitHub Releases |
| In-app updates | Use Sparkle with `ZIP + appcast.xml` |
| Update host | Use Cloudflare R2 for appcast and Sparkle ZIPs |
| Distribution split | Use dual-track delivery: DMG on GitHub Releases, ZIP/appcast on R2 |
| Default update behavior | Automatic checks + automatic downloads |
| App integration style | Programmatic Sparkle setup behind a Quickey service abstraction |
| Feed signing | Do not enable `SURequireSignedFeed` in the first version |
| Packaging source of truth | Keep `scripts/package-app.sh` as the single `.app` packager |
| CI secret policy | Ordinary CI remains credential-free; release workflow owns credentials |

## Approaches Considered

### 1. Minimal app-only Sparkle integration

Add Sparkle to the app, wire a check-for-updates button, and defer packaging plus release automation.

Pros:
- Smallest code change
- Fastest visible UI win

Cons:
- Not actually shippable
- Would leave update archives, appcast generation, and hosting unsolved
- High risk of integrating the UI before proving the packaging path

### 2. App integration plus local packaging only

Add Sparkle to the app and teach local packaging to produce a Sparkle-compatible app and ZIP, but stop before release automation and R2 publishing.

Pros:
- More realistic than UI-only work
- De-risks framework embedding and ZIP generation

Cons:
- Still leaves the release system incomplete
- Creates a half-implemented distribution story that maintainers cannot actually use

### 3. Full dual-track release pipeline

Add app-side Sparkle integration, Sparkle-compatible packaging, ZIP/appcast generation, R2 publication, and release workflow changes while preserving the DMG release path.

Pros:
- Produces a complete, shippable update system
- Keeps first-install and in-app update concerns separate
- Limits the blast radius of failures by not replacing the current DMG path

Cons:
- Broadest implementation surface
- Requires more secrets, docs, and macOS runtime verification

### Recommendation

Use approach 3. Issue `#175` explicitly asks for a complete Sparkle-based update flow, and anything less leaves Quickey with a partially integrated updater that cannot actually be released safely.

## Design

### 1. App-Side Update Architecture

Quickey should expose a small app-owned update boundary rather than letting Sparkle APIs leak into UI code.

Add a new service abstraction in `Sources/Quickey/Services/`:

- `UpdateServicing`
- `SparkleUpdateService`

`UpdateServicing` should answer only the needs Quickey currently has:

- whether the updater is available
- whether a manual update check can be triggered
- a `checkForUpdates()` action
- lightweight display information such as the current version and whether automatic checks/downloads are the configured defaults

`SparkleUpdateService` should own the real Sparkle objects and lifecycle. It should be created once by `AppController` during startup and held for the lifetime of the app. This avoids tying updater lifetime to window creation and matches Sparkle's expectation that the updater is a long-lived controller.

`SettingsWindowController` should receive the shared update service from `AppController`, inject it into `AppPreferences`, and then `GeneralTabView` should render an `Updates` section based on an `AppPreferences`-level presentation model. `GeneralTabView` should not import Sparkle directly.

The General tab should add:

- a `Check for Updates…` button
- a short explanation that Quickey checks automatically and downloads updates in the background by default
- existing version display retained in the About card or moved into the new Updates section only if the layout remains clear

This keeps responsibilities clear:

- `SparkleUpdateService`: Sparkle lifecycle and side effects
- `AppPreferences`: UI-facing update presentation and commands
- `GeneralTabView`: layout, copy, and button wiring

### 2. Sparkle Configuration and Defaults

Quickey should configure Sparkle defaults in `Sources/Quickey/Resources/Info.plist`:

- `SUFeedURL`
- `SUPublicEDKey`
- `SUEnableAutomaticChecks = YES`
- `SUScheduledCheckInterval = 86400`
- `SUAutomaticallyUpdate = YES`
- `SUAllowsAutomaticUpdates = YES`
- `SUEnableSystemProfiling = NO`

This avoids Sparkle's second-launch permission prompt for automatic checks and aligns the app with the approved product behavior: automatic checking plus automatic downloading by default.

I am intentionally not recommending:

- `SURequireSignedFeed`
- `SUVerifyUpdateBeforeExtraction`

for the first rollout. Sparkle documents those as stronger but more operationally strict settings. They are reasonable future hardening steps, but they add key-management and recovery burden that is not necessary to ship a secure EdDSA-signed update archive flow now.

### 3. Packaging Architecture

Quickey's packaged app remains the single source of truth for all release artifacts.

The layered packaging flow becomes:

1. `scripts/package-app.sh`
2. `scripts/package-dmg.sh`
3. `scripts/package-update-zip.sh`
4. `scripts/generate-appcast.sh`

#### `Package.swift`

Add the `sparkle-project/Sparkle` dependency to the `Quickey` target and add the runpath necessary for the packaged app to load the embedded framework:

- `@executable_path/../Frameworks`

Quickey's manual packaging path currently bypasses Xcode's normal "Embed & Sign" behavior, so the package and scripts must explicitly account for framework embedding.

#### `scripts/package-app.sh`

Extend the app packaging script so it:

- builds the release binary
- creates `build/Quickey.app`
- embeds `Sparkle.framework` under `Contents/Frameworks`
- preserves Sparkle's symlinks and executable permissions when copying
- copies `Info.plist` and app resources as before
- signs nested Sparkle helpers explicitly instead of relying on `--deep`
- signs the final app bundle

Because Quickey does not use Xcode archive/export, it should follow Sparkle's manual-signing guidance for non-standard distribution workflows. That means:

- sign Sparkle helper binaries first
- sign `Sparkle.framework`
- sign `Quickey.app` last

Quickey is not sandboxed, so it may optionally remove Sparkle XPC services it does not need to reduce bundle size. This is an optimization, not a requirement for the first implementation.

#### `scripts/package-update-zip.sh`

Add a new script that packages `build/Quickey.app` into the Sparkle update archive:

- output: `build/Quickey-<CFBundleShortVersionString>.zip`
- use `ditto -c -k --sequesterRsrc --keepParent`

This follows Sparkle's documented ZIP creation guidance and ensures the archive preserves the bundle structure Sparkle expects.

#### `scripts/generate-appcast.sh`

Add a script that:

- reads `CFBundleShortVersionString`, `CFBundleVersion`, and `LSMinimumSystemVersion`
- takes the just-built ZIP and release notes input
- calls Sparkle's `generate_appcast`
- emits `build/appcast.xml`

The appcast should publish:

- `sparkle:version` from `CFBundleVersion`
- `sparkle:shortVersionString` from `CFBundleShortVersionString`
- `sparkle:minimumSystemVersion` from `LSMinimumSystemVersion`
- R2-hosted ZIP URL
- EdDSA signature generated by Sparkle tooling

### 4. Release and Hosting Architecture

Use dual-track hosting:

- GitHub Releases hosts the signed/notarized DMG
- Cloudflare R2 hosts Sparkle's ZIPs and `appcast.xml`

Recommended R2 layout:

- `quickey/appcast.xml`
- `quickey/Quickey-<version>.zip`

The DMG remains on GitHub Releases because that is already Quickey's documented first-install path. The ZIP and appcast move to R2 because Sparkle needs a stable feed URL and direct archive hosting independent of GitHub's release page UX.

### 5. GitHub Actions Responsibilities

#### Ordinary CI

`.github/workflows/ci.yml` should remain credential-free and verify structure only:

- `swift build`
- `swift test`
- `scripts/package-app.sh`
- verify `Contents/Frameworks/Sparkle.framework`
- `scripts/package-dmg.sh`
- `scripts/package-update-zip.sh`
- verify DMG and ZIP exist

No R2 publishing or EdDSA signing secrets should be referenced from ordinary CI.

#### Internal Package Workflow

`.github/workflows/internal-package.yml` should keep its current purpose:

- build unsigned internal test artifacts
- publish a rolling internal DMG prerelease

It should not publish `appcast.xml` or Sparkle ZIPs. Internal prerelease distribution is for trusted testers; it is not the official Sparkle update channel.

#### Release Workflow

`.github/workflows/release.yml` should continue to trigger on `v*` tags and should additionally:

1. build and test
2. package the Sparkle-enabled app
3. package the Sparkle ZIP
4. generate `appcast.xml`
5. upload ZIP and `appcast.xml` to R2
6. package, sign, notarize, staple, and validate the DMG
7. publish or update the GitHub Release with the DMG

The workflow must fail closed. If any packaging, signing, appcast generation, R2 upload, notarization, or validation step fails, no official release should be published.

### 6. Secrets and Credentials

The repository already needs Developer ID and notary credentials for DMG release publication. Sparkle and R2 add a second credential group.

Recommended additional secrets:

- `SPARKLE_PUBLIC_ED_KEY`
- `SPARKLE_PRIVATE_ED_KEY`
- `R2_ACCOUNT_ID`
- `R2_ACCESS_KEY_ID`
- `R2_SECRET_ACCESS_KEY`
- `R2_BUCKET`
- `R2_PUBLIC_BASE_URL`

If Sparkle tooling is sourced from the SwiftPM checkout rather than an external install, the release workflow should resolve its path deterministically and fail with a clear error if the tools are not present.

### 7. Testing Strategy

Highest-value automated coverage:

- `AppPreferences` tests for update presentation mapping and command delegation
- `SettingsView` or view-model-level tests for update button availability and copy
- shell or workflow-level assertions that:
  - `build/Quickey.app` contains `Contents/Frameworks/Sparkle.framework`
  - the Sparkle ZIP exists and is named correctly
  - `appcast.xml` contains the expected version and URL data

Because the packaging scripts are shell-based and the environment is macOS-specific, structural checks in CI are more valuable here than trying to fake full updater behavior in unit tests.

### 8. macOS Runtime Validation Requirements

This issue is runtime-sensitive and cannot be claimed correct from Linux inspection alone.

Mandatory macOS validation after implementation:

- launch packaged `Quickey.app` from `/Applications`
- confirm `Check for Updates…` opens Sparkle's standard flow
- point the app at a test appcast and confirm update discovery
- validate background download behavior with `SUAutomaticallyUpdate = YES`
- verify installation/relaunch into the newer version
- verify the updated app still behaves correctly with:
  - Accessibility permission
  - Input Monitoring permission
  - event tap startup
  - launch-at-login presentation

PRs or branches touching this work should remain `macOS runtime validation pending` until the above completes.

## Acceptance Criteria

- Quickey exposes a working `Check for Updates…` action in the General tab
- `Quickey.app` can load its embedded Sparkle framework without runtime loader errors
- the release workflow can produce:
  - a signed/notarized DMG for GitHub Releases
  - a Sparkle ZIP
  - an `appcast.xml`
  - R2-hosted update artifacts
- ordinary CI stays credential-free
- docs explain the dual-track distribution model and required secrets
- macOS-only validation requirements are documented, not implied away

## Implementation Notes For Planning

- Keep Sparkle imports out of SwiftUI files
- Reuse existing `AppPreferences` presentation-model patterns rather than creating a parallel view-specific state system
- Avoid `codesign --deep`; nested signing should be explicit and deterministic
- Preserve Sparkle framework symlinks and executable bits when copying into the app bundle
- Prefer one-source-of-truth versioning from `Info.plist`
- Do not silently publish partial release state if R2 upload or appcast generation fails
