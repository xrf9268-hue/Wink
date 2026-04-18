# Sparkle Auto Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship issue `#175` by integrating Sparkle into Quickey's app lifecycle, packaging a Sparkle-compatible app and update ZIP, publishing Sparkle metadata to Cloudflare R2, and preserving the current DMG-based first-install release path.

**Architecture:** Add a small Quickey-owned update service boundary that wraps Sparkle and is injected through `AppController` into `AppPreferences` and the General settings tab. Keep `scripts/package-app.sh` as the single `.app` bundle source of truth, layer `package-dmg.sh`, `package-update-zip.sh`, and `generate-appcast.sh` on top of it, and extend the tag-driven release workflow so DMG publication and Sparkle ZIP/appcast publication happen together but fail closed.

**Tech Stack:** Swift 6, SwiftPM, AppKit, SwiftUI, Sparkle, Bash, GitHub Actions, Cloudflare R2, macOS command-line tooling (`codesign`, `ditto`, `hdiutil`, `xcrun notarytool`, `xcrun stapler`), Markdown

**Spec:** `docs/superpowers/specs/2026-04-18-sparkle-auto-update-design.md`

---

## File Structure

- `Package.swift`
  Add Sparkle as a dependency and add the runpath needed by the packaged app.

- `Sources/Quickey/Services/UpdateServicing.swift`
  New app-owned protocol and lightweight update display model.

- `Sources/Quickey/Services/SparkleUpdateService.swift`
  Sparkle-backed implementation that owns updater lifecycle and manual update actions.

- `Sources/Quickey/Services/AppPreferences.swift`
  Extend preferences with update presentation and command delegation.

- `Sources/Quickey/AppController.swift`
  Create and retain the shared update service during app startup.

- `Sources/Quickey/UI/SettingsWindowController.swift`
  Inject the shared update service into `AppPreferences`.

- `Sources/Quickey/UI/GeneralTabView.swift`
  Add the `Updates` section and wire the manual check action.

- `Sources/Quickey/Resources/Info.plist`
  Add Sparkle configuration defaults and placeholders for feed/public key.

- `Tests/QuickeyTests/AppPreferencesTests.swift`
  Add tests for update presentation mapping and command delegation.

- `Tests/QuickeyTests/SettingsViewTests.swift`
  Add view-lifecycle or UI-facing tests for the update section state.

- `scripts/package-app.sh`
  Embed Sparkle.framework, preserve symlinks, and explicitly sign nested components.

- `scripts/package-update-zip.sh`
  New Sparkle update ZIP packager.

- `scripts/generate-appcast.sh`
  New Sparkle appcast generator.

- `.github/workflows/ci.yml`
  Verify Sparkle-enabled packaging structure without secrets.

- `.github/workflows/release.yml`
  Generate ZIP/appcast, upload to R2, and keep DMG release publication.

- `README.md`
- `docs/README.md`
- `docs/signing-and-release.md`
- `docs/handoff-notes.md`
- `docs/architecture.md`
  Update user-facing, maintainer, release, and architecture documentation.

## Scope Guardrails

- Do not replace the DMG as the first-install artifact.
- Do not enable signed appcasts in this implementation.
- Do not make ordinary CI depend on Sparkle private keys, R2 credentials, or Apple credentials.
- Do not claim full correctness without macOS runtime update validation.
- Keep Sparkle APIs out of SwiftUI files.
- Do not use `codesign --deep` as a substitute for nested-signing discipline.

### Task 1: Add an app-owned update service seam

**Files:**
- Create: `Sources/Quickey/Services/UpdateServicing.swift`
- Modify: `Sources/Quickey/Services/AppPreferences.swift`
- Test: `Tests/QuickeyTests/AppPreferencesTests.swift`

- [ ] **Step 1: Write the failing update-presentation tests**

Add tests that describe the desired behavior:

```swift
@Test @MainActor
func updatePresentation_exposesVersionAndEnablesManualChecksWhenServiceIsAvailable() {
    let service = FakeUpdateService(
        isAvailable: true,
        canCheckForUpdates: true,
        currentVersion: "0.3.0"
    )
    let preferences = makePreferences(updateService: service)

    let presentation = preferences.updatePresentation
    #expect(presentation.currentVersion == "0.3.0")
    #expect(presentation.checkForUpdatesEnabled == true)
}

@Test @MainActor
func updatePresentation_checkForUpdatesDelegatesToService() {
    let service = FakeUpdateService(isAvailable: true, canCheckForUpdates: true, currentVersion: "0.3.0")
    let preferences = makePreferences(updateService: service)

    preferences.checkForUpdates()

    #expect(service.didRequestManualCheck == true)
}
```

- [ ] **Step 2: Run the focused tests and verify they fail for the right reason**

Run:

```bash
swift test --filter AppPreferencesTests
```

Expected:
- the new tests fail because `AppPreferences` and the new protocol/model do not exist yet

- [ ] **Step 3: Add the protocol and minimal `AppPreferences` integration**

Implement:

- `UpdateServicing`
- a lightweight `UpdatePresentation`
- `AppPreferences.updatePresentation`
- `AppPreferences.checkForUpdates()`

Keep the model intentionally small:

```swift
struct UpdatePresentation: Equatable {
    let currentVersion: String
    let checkForUpdatesEnabled: Bool
    let automaticChecksEnabledByDefault: Bool
    let automaticDownloadsEnabledByDefault: Bool
}
```

- [ ] **Step 4: Re-run the focused tests and keep them green**

Run:

```bash
swift test --filter AppPreferencesTests
```

Expected:
- the new update-presentation tests pass

- [ ] **Step 5: Commit the service seam**

Run:

```bash
git add Sources/Quickey/Services/UpdateServicing.swift Sources/Quickey/Services/AppPreferences.swift Tests/QuickeyTests/AppPreferencesTests.swift
git commit -m "feat: add update service seam"
```

### Task 2: Add the General tab update UI

**Files:**
- Modify: `Sources/Quickey/UI/GeneralTabView.swift`
- Modify: `Tests/QuickeyTests/SettingsViewTests.swift`

- [ ] **Step 1: Write the failing UI-facing tests**

Add tests for the new settings presentation:

```swift
@Test @MainActor
func generalTabUpdatePresentation_showsManualCheckActionWhenEnabled() {
    let service = FakeUpdateService(isAvailable: true, canCheckForUpdates: true, currentVersion: "0.3.0")
    let preferences = makePreferences(updateService: service)

    let presentation = preferences.updatePresentation

    #expect(presentation.checkForUpdatesEnabled == true)
    #expect(presentation.currentVersion == "0.3.0")
}
```

If the repository's current settings tests are better expressed through view lifecycle helpers, adapt the assertion layer but keep the test focused on update section availability and copy.

- [ ] **Step 2: Run the focused settings tests and verify red**

Run:

```bash
swift test --filter SettingsViewTests
```

Expected:
- the new expectations fail because the General tab does not expose an Updates section yet

- [ ] **Step 3: Add the minimal General tab UI**

Update `GeneralTabView` to add an `Updates` card containing:

- a `Check for Updates…` button bound to `preferences.checkForUpdates()`
- concise copy about automatic checks and downloads by default
- visible current version text sourced from `preferences.updatePresentation`

Keep the layout visually aligned with existing cards and avoid importing Sparkle in the view.

- [ ] **Step 4: Re-run the focused settings tests**

Run:

```bash
swift test --filter SettingsViewTests
```

Expected:
- the new settings-facing tests pass

- [ ] **Step 5: Commit the UI layer**

Run:

```bash
git add Sources/Quickey/UI/GeneralTabView.swift Tests/QuickeyTests/SettingsViewTests.swift
git commit -m "feat: add settings update controls"
```

### Task 3: Wire the shared Sparkle service into the app lifecycle

**Files:**
- Create: `Sources/Quickey/Services/SparkleUpdateService.swift`
- Modify: `Sources/Quickey/AppController.swift`
- Modify: `Sources/Quickey/UI/SettingsWindowController.swift`
- Modify: `Package.swift`
- Modify: `Sources/Quickey/Resources/Info.plist`

- [ ] **Step 1: Capture the missing Sparkle integration points**

Run:

```bash
rg -n "Sparkle|UpdateServicing|checkForUpdates|SUFeedURL|SUPublicEDKey" Package.swift Sources/Quickey
```

Expected before changes:
- no Sparkle dependency
- no Sparkle-backed update service
- no Sparkle Info.plist keys

- [ ] **Step 2: Add Sparkle dependency and Info.plist defaults**

Update `Package.swift` to:

- add the Sparkle package dependency
- make the `Quickey` executable target depend on Sparkle
- add linker flags for `@executable_path/../Frameworks`

Update `Info.plist` to add:

- `SUFeedURL`
- `SUPublicEDKey`
- `SUEnableAutomaticChecks`
- `SUScheduledCheckInterval`
- `SUAutomaticallyUpdate`
- `SUAllowsAutomaticUpdates`
- `SUEnableSystemProfiling`

Use placeholder values where secrets or environment-specific URLs are not committed directly.

- [ ] **Step 3: Implement the Sparkle-backed service**

Create `SparkleUpdateService.swift` that:

- imports Sparkle
- owns the updater controller for the app lifetime
- conforms to `UpdateServicing`
- exposes `checkForUpdates()`
- keeps Sparkle-specific types private to the file where possible

Prefer the standard programmatic Sparkle controller rather than scattering updater setup in the window layer.

- [ ] **Step 4: Inject the shared service through the app shell**

Update:

- `AppController` to create and retain the update service
- `SettingsWindowController` to accept and reuse the shared service when building `AppPreferences`

Do not recreate a new Sparkle controller every time the settings window opens.

- [ ] **Step 5: Run the focused app and settings tests**

Run:

```bash
swift test --filter AppPreferencesTests
swift test --filter SettingsViewTests
```

Expected:
- previously-added tests stay green after the real service is introduced

- [ ] **Step 6: Commit the app integration**

Run:

```bash
git add Package.swift Sources/Quickey/AppController.swift Sources/Quickey/UI/SettingsWindowController.swift Sources/Quickey/Resources/Info.plist Sources/Quickey/Services/SparkleUpdateService.swift
git commit -m "feat: integrate Sparkle update service"
```

### Task 4: Teach the app packager to embed and sign Sparkle

**Files:**
- Modify: `scripts/package-app.sh`

- [ ] **Step 1: Write the failing packaging assertions**

Add or document a structure check you can run after packaging:

```bash
bash scripts/package-app.sh
test -d build/Quickey.app/Contents/Frameworks/Sparkle.framework
```

Expected before changes:
- the framework check fails because Sparkle is not embedded into the packaged app

- [ ] **Step 2: Embed Sparkle.framework in the packaged app**

Update `scripts/package-app.sh` to:

- locate the Sparkle framework from the SwiftPM build artifacts
- copy it into `build/Quickey.app/Contents/Frameworks/` using a tool that preserves symlinks and executable permissions
- keep existing app resource copying intact

Prefer `ditto` over a plain recursive `cp`.

- [ ] **Step 3: Add explicit nested signing**

Update the script to sign in deterministic order:

```bash
codesign -f -s "$SIGN_IDENTITY" -o runtime "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate"
codesign -f -s "$SIGN_IDENTITY" -o runtime "$SPARKLE_FRAMEWORK/Versions/B/Updater.app"
codesign -f -s "$SIGN_IDENTITY" -o runtime "$SPARKLE_FRAMEWORK"
codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP_DIR"
```

Adjust flags for local fallback versus release mode, but do not replace explicit nested signing with `--deep`.

- [ ] **Step 4: Re-run the packaging assertions**

Run:

```bash
bash scripts/package-app.sh
test -d build/Quickey.app/Contents/Frameworks/Sparkle.framework
codesign --verify --deep --strict --verbose=2 build/Quickey.app
```

Expected:
- the framework exists
- the app verifies successfully

- [ ] **Step 5: Commit the packaging change**

Run:

```bash
git add scripts/package-app.sh
git commit -m "build: embed and sign Sparkle framework"
```

### Task 5: Add Sparkle ZIP and appcast generation

**Files:**
- Create: `scripts/package-update-zip.sh`
- Create: `scripts/generate-appcast.sh`

- [ ] **Step 1: Write the failing archive-generation checks**

Run:

```bash
test -f scripts/package-update-zip.sh
test -f scripts/generate-appcast.sh
```

Expected before changes:
- both checks fail because the scripts do not exist

- [ ] **Step 2: Add `scripts/package-update-zip.sh`**

Create a script that:

- ensures `build/Quickey.app` exists
- reads `CFBundleShortVersionString`
- emits `build/Quickey-<version>.zip`
- uses:

```bash
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"
```

- [ ] **Step 3: Add `scripts/generate-appcast.sh`**

Create a script that:

- resolves Sparkle's `generate_appcast` tool
- reads the versioning data from `Info.plist`
- takes R2 base URL and release notes input from environment variables or arguments
- outputs `build/appcast.xml`

Make the script fail clearly if:

- the Sparkle tool cannot be found
- required key material is missing
- the ZIP does not exist

- [ ] **Step 4: Run the new scripts and verify green**

Run:

```bash
bash scripts/package-update-zip.sh
test -f build/Quickey-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Sources/Quickey/Resources/Info.plist).zip
```

Then run `generate-appcast.sh` with test-only environment values appropriate for the implementation.

Expected:
- ZIP exists
- appcast is generated into `build/appcast.xml`

- [ ] **Step 5: Commit the update archive tools**

Run:

```bash
git add scripts/package-update-zip.sh scripts/generate-appcast.sh
git commit -m "build: add Sparkle archive generation"
```

### Task 6: Extend CI and release automation

**Files:**
- Modify: `.github/workflows/ci.yml`
- Modify: `.github/workflows/release.yml`

- [ ] **Step 1: Add the failing CI structure expectations**

Describe the expected new ordinary CI checks:

```yaml
      - name: Verify Sparkle framework
        run: test -d build/Quickey.app/Contents/Frameworks/Sparkle.framework

      - name: Package update ZIP
        run: bash scripts/package-update-zip.sh
```

Expected before changes:
- CI does not verify Sparkle packaging or ZIP generation

- [ ] **Step 2: Extend ordinary CI**

Update `.github/workflows/ci.yml` to:

- package the app
- verify `Sparkle.framework`
- package the DMG
- package the update ZIP
- verify the ZIP path exists

Keep CI free of Apple, Sparkle private key, and R2 secrets.

- [ ] **Step 3: Extend the release workflow**

Update `.github/workflows/release.yml` to:

- build/test as before
- package the Sparkle-enabled app
- package the Sparkle ZIP
- generate `appcast.xml`
- upload ZIP and `appcast.xml` to R2
- continue with DMG packaging, notarization, stapling, validation, and GitHub Release publication

Ensure R2 publication happens only after local artifacts are successfully generated and validated.

- [ ] **Step 4: Add clear failure gates**

Verify the workflow fails if:

- Sparkle tooling is missing
- key material is missing
- R2 upload fails
- appcast generation fails
- notarization or stapling fails

Do not allow a partial official release.

- [ ] **Step 5: Commit the workflow changes**

Run:

```bash
git add .github/workflows/ci.yml .github/workflows/release.yml
git commit -m "ci: publish Sparkle update artifacts"
```

### Task 7: Update maintainer and user documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/README.md`
- Modify: `docs/signing-and-release.md`
- Modify: `docs/handoff-notes.md`
- Modify: `docs/architecture.md`

- [ ] **Step 1: Capture the missing update docs**

Run:

```bash
rg -n "Sparkle|appcast|Cloudflare R2|Check for Updates|automatic updates" README.md docs
```

Expected before changes:
- the current docs describe DMG releases but not the Sparkle update path

- [ ] **Step 2: Update the docs**

Document:

- DMG-first install plus Sparkle-based update flow
- required Sparkle/R2 secrets
- release order and failure gates
- General tab update entry point
- architecture boundary for the new update service
- macOS runtime validation still required after implementation

- [ ] **Step 3: Verify doc consistency**

Run:

```bash
rg -n "internal-downloads|DMG|Sparkle|appcast|R2|Check for Updates" README.md docs
```

Expected:
- the docs consistently describe the dual-track distribution model

- [ ] **Step 4: Commit the documentation update**

Run:

```bash
git add README.md docs/README.md docs/signing-and-release.md docs/handoff-notes.md docs/architecture.md
git commit -m "docs: document Sparkle update flow"
```

### Task 8: Final verification and macOS validation handoff

**Files:**
- Verify only

- [ ] **Step 1: Run the repository verification commands**

Run:

```bash
swift build
swift test
bash scripts/package-app.sh
bash scripts/package-dmg.sh
bash scripts/package-update-zip.sh
```

Expected:
- all commands exit 0 on macOS with the required toolchain installed

- [ ] **Step 2: Verify release structure locally**

Run:

```bash
test -d build/Quickey.app/Contents/Frameworks/Sparkle.framework
test -f build/appcast.xml
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Sources/Quickey/Resources/Info.plist)"
test -f "build/Quickey-${VERSION}.zip"
test -f "build/Quickey-${VERSION}.dmg"
```

Expected:
- all required artifacts exist

- [ ] **Step 3: Record macOS-only runtime validation still required**

Document and manually verify on macOS:

- Sparkle can check for updates from `/Applications/Quickey.app`
- test appcast discovery works
- automatic background download behavior matches defaults
- install/relaunch succeeds into the updated version
- TCC-sensitive Quickey behavior still works after update

- [ ] **Step 4: Commit the verification-backed finish**

Run:

```bash
git add .
git commit -m "feat: add Sparkle auto update pipeline"
```
