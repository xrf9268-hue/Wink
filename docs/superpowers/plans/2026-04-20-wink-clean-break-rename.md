# Wink Clean-Break Rename Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the in-repo `Quickey` identity with `Wink` across package layout, runtime metadata, storage/logging paths, scripts, CI, tests, and primary docs, with no compatibility layer for old names or paths.

**Architecture:** Treat the rename as a repository-wide identity reset, not a cosmetic string swap. Rename the SPM graph and source/test roots first so the codebase has one internal name, then update runtime identity and path-bearing tests, then update scripts/automation, then correct docs and historical notes, and finish with a verification pass that proves the clean-break surfaces now point only at `Wink`.

**Tech Stack:** Swift 6, Swift Package Manager, Swift Testing, Bash/Bats, GitHub Actions YAML, Foundation, ServiceManagement, AppKit packaging scripts

---

## File Map

### Package graph and root layout
- `Package.swift`
  Purpose: canonical Swift package, executable product, executable target, and test target names.
- `Sources/Quickey/` -> `Sources/Wink/`
  Purpose: app source root and bundled resources move under the new target name.
- `Tests/QuickeyTests/` -> `Tests/WinkTests/`
  Purpose: test target root must match the renamed SPM test target.

### Runtime identity and persisted paths
- `Sources/Wink/Resources/Info.plist`
  Purpose: `CFBundleExecutable`, `CFBundleIdentifier`, app display names, and `OSLogPreferences`.
- `Sources/Wink/Services/StoragePaths.swift`
  Purpose: default `Application Support/Wink` identity root.
- `Sources/Wink/Services/DiagnosticLog.swift`
  Purpose: `com.wink.app` subsystem and `~/.config/Wink/debug.log`.
- `Sources/Wink/Services/DiagnosticLogWriter.swift`
  Purpose: queue label should no longer use `quickey`.
- `Sources/Wink/Services/AppPreferences.swift`
  Purpose: launch-at-login user-facing strings mentioning `Quickey` / `Quickey.app`.

### Scripts and automation
- `scripts/package-app.sh`
  Purpose: build `Wink`, package `build/Wink.app`, sign as `com.wink.app`.
- `scripts/package-dmg.sh`
  Purpose: package `build/Wink-<version>.dmg` from `build/Wink.app`.
- `scripts/e2e-lib.sh`
  Purpose: E2E defaults for app path, bundle id, log path, and shortcuts path.
- `scripts/e2e-lib.bats`
  Purpose: regression test for E2E helper defaults.
- `scripts/e2e-full-test.sh`
  Purpose: user-facing E2E banner/help text should match `Wink`.
- `.github/workflows/ci.yml`
  Purpose: verify renamed app bundle and DMG paths.
- `.github/workflows/release.yml`
  Purpose: release verification paths and artifact names.
- `.github/workflows/internal-package.yml`
  Purpose: tester instructions should refer to `Wink.app`.
- `.github/scripts/lib/project-automation.mjs`
  Purpose: runtime-sensitive file classification must follow `Sources/Wink/...`.

### Tests and primary docs
- `Tests/WinkTests/PersistenceServiceTests.swift`
  Purpose: assert live path reference now points to `Application Support/Wink`.
- `Tests/WinkTests/LaunchAtLoginServiceTests.swift`
  Purpose: assert bundle URL paths use `Wink.app`.
- `Tests/WinkTests/AppPreferencesTests.swift`
  Purpose: assert launch-at-login presentation strings use `Wink`.
- `Tests/WinkTests/DiagnosticLogIdentityTests.swift`
  Purpose: explicit regression test for `DiagnosticLog.subsystem` and `logFileURL`.
- `README.md`, `AGENTS.md`, `docs/README.md`, `docs/handoff-notes.md`, `docs/archive/issue-183-wink-rename-evaluation.md`, `worker/src/index.ts`
  Purpose: user-facing and maintainer-facing identity and historical status.

---

### Task 1: Rename the SPM graph and source/test roots

**Files:**
- Modify: `Package.swift`
- Move: `Sources/Quickey` -> `Sources/Wink`
- Move: `Tests/QuickeyTests` -> `Tests/WinkTests`
- Modify: `Tests/WinkTests/PersistenceServiceTests.swift`
- Modify: `Tests/WinkTests/DiagnosticLogTests.swift`
- Modify: `Tests/WinkTests/LaunchAtLoginServiceTests.swift`
- Modify: `Tests/WinkTests/TestSupport/TestPersistenceHarness.swift`

- [ ] **Step 1: Write the failing test**

Change the representative test imports to the future module name before touching the package graph:

```swift
import Foundation
import Testing
@testable import Wink
```

Apply that import change in:

- `Tests/QuickeyTests/PersistenceServiceTests.swift`
- `Tests/QuickeyTests/DiagnosticLogTests.swift`
- `Tests/QuickeyTests/LaunchAtLoginServiceTests.swift`
- `Tests/QuickeyTests/TestSupport/TestPersistenceHarness.swift`

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
swift test --filter PersistenceServiceDiskLoadingTests
```

Expected: FAIL during compilation with `no such module 'Wink'`.

- [ ] **Step 3: Write minimal implementation**

Rename the roots and update the package graph in one change set:

```bash
git mv Sources/Quickey Sources/Wink
git mv Tests/QuickeyTests Tests/WinkTests
```

Replace `Package.swift` with:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Wink",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "Wink", targets: ["Wink"])
    ],
    targets: [
        .executableTarget(
            name: "Wink",
            path: "Sources/Wink",
            exclude: [
                "Resources/Info.plist",
                "Resources/AppIcon.svg",
                "Resources/AppIcon.icns",
            ],
            swiftSettings: [
                .define("DEBUG", .when(configuration: .debug)),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .unsafeFlags(["-F/System/Library/PrivateFrameworks", "-framework", "SkyLight"]),
            ]
        ),
        .testTarget(
            name: "WinkTests",
            dependencies: ["Wink"],
            path: "Tests/WinkTests"
        )
    ]
)
```

Then replace remaining test imports:

```bash
rg -l '@testable import Quickey' Tests/WinkTests | xargs perl -0pi -e 's/@testable import Quickey/@testable import Wink/g'
```

- [ ] **Step 4: Run test to verify it passes**

Run:

```bash
swift test --filter PersistenceServiceDiskLoadingTests
swift test --filter concurrentWritesProduceOneLinePerMessage
```

Expected: PASS. The package now resolves `Wink` as both the executable target and the testable module.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/Wink Tests/WinkTests
git commit -m "refactor: rename package graph to Wink"
```

### Task 2: Rename runtime identity and persisted path seams

**Files:**
- Create: `Tests/WinkTests/DiagnosticLogIdentityTests.swift`
- Modify: `Sources/Wink/Resources/Info.plist`
- Modify: `Sources/Wink/Services/StoragePaths.swift`
- Modify: `Sources/Wink/Services/DiagnosticLog.swift`
- Modify: `Sources/Wink/Services/DiagnosticLogWriter.swift`
- Modify: `Sources/Wink/Services/AppPreferences.swift`
- Modify: `Tests/WinkTests/PersistenceServiceTests.swift`
- Modify: `Tests/WinkTests/LaunchAtLoginServiceTests.swift`
- Modify: `Tests/WinkTests/AppPreferencesTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/WinkTests/DiagnosticLogIdentityTests.swift`:

```swift
import Foundation
import Testing
@testable import Wink

@Suite("DiagnosticLog identity")
struct DiagnosticLogIdentityTests {
    @Test
    func usesWinkSubsystemAndLogPath() {
        #expect(DiagnosticLog.subsystem == "com.wink.app")
        #expect(DiagnosticLog.logFileURL().path.hasSuffix("/.config/Wink/debug.log"))
    }
}
```

Update existing expectations to the future `Wink` identity:

```swift
let liveShortcutsURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Wink", isDirectory: true)
    .appendingPathComponent("shortcuts.json")
```

```swift
bundleURL: { URL(fileURLWithPath: "/Applications/Wink.app") }
bundleURL: { URL(fileURLWithPath: "/Users/yvan/developer/Quickey/build/Wink.app") }
```

```swift
#expect(presentation.message == "Wink is registered to launch at login, but macOS still needs your approval in Login Items.")
#expect(presentation.message == "Launch at Login is only available after installing Wink.app in the Applications folder and reopening it.")
#expect(presentation.message == "Wink couldn't find its login item configuration. This usually points to an installation or packaging problem.")
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
swift test --filter DiagnosticLogIdentityTests
swift test --filter LaunchAtLoginPresentation_requiresApprovalMapsToInformationalStateWithOpenSettingsCTA
```

Expected:
- `DiagnosticLogIdentityTests` fails because `DiagnosticLog.subsystem` and `logFileURL` still point at `Quickey`
- the launch-at-login presentation test fails because the UI strings still mention `Quickey`

- [ ] **Step 3: Write minimal implementation**

Update the runtime identity sources.

Use these exact values in `Sources/Wink/Resources/Info.plist`:

```xml
<key>CFBundleExecutable</key><string>Wink</string>
<key>CFBundleIdentifier</key><string>com.wink.app</string>
<key>CFBundleName</key><string>Wink</string>
<key>CFBundleDisplayName</key><string>Wink</string>
```

Replace the `OSLogPreferences` key path with:

```xml
<key>OSLogPreferences</key>
<dict>
  <key>com.wink.app</key>
  <dict>
    <key>DEFAULT-OPTIONS</key>
    <dict>
      <key>Level</key>
      <dict>
        <key>Enable</key><string>Debug</string>
        <key>Persist</key><string>Info</string>
      </dict>
    </dict>
  </dict>
</dict>
```

Update `StoragePaths.swift` and `DiagnosticLog.swift` to the new identity:

```swift
enum StoragePaths {
    static let appDirectoryName = "Wink"
```

```swift
enum DiagnosticLog: Sendable {
    static let subsystem = "com.wink.app"

    private static let logURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/Wink/debug.log")
```

Update the writer queue label in `DiagnosticLogWriter.swift`:

```swift
queue: DispatchQueue = DispatchQueue(label: "com.wink.diagnostic-log")
```

Update the launch-at-login presentation strings in `AppPreferences.swift` exactly:

```swift
message: "Wink is registered to launch at login, but macOS still needs your approval in Login Items."
```

```swift
message: "Launch at Login is only available after installing Wink.app in the Applications folder and reopening it."
```

```swift
message: "Wink couldn't find its login item configuration. This usually points to an installation or packaging problem."
```

- [ ] **Step 4: Run test to verify it passes**

Run:

```bash
swift test --filter DiagnosticLogIdentityTests
swift test --filter PersistenceServiceDiskLoadingTests
swift test --filter notFoundOutsideApplicationsRequiresAppInstallation
swift test --filter notFoundInsideApplicationsStaysConfigurationMissing
swift test --filter LaunchAtLoginPresentation_requiresApprovalMapsToInformationalStateWithOpenSettingsCTA
```

Expected: PASS. The runtime identity seams now point only at `Wink`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Wink/Resources/Info.plist Sources/Wink/Services/StoragePaths.swift Sources/Wink/Services/DiagnosticLog.swift Sources/Wink/Services/DiagnosticLogWriter.swift Sources/Wink/Services/AppPreferences.swift Tests/WinkTests/PersistenceServiceTests.swift Tests/WinkTests/LaunchAtLoginServiceTests.swift Tests/WinkTests/AppPreferencesTests.swift Tests/WinkTests/DiagnosticLogIdentityTests.swift
git commit -m "refactor: rename runtime identity to Wink"
```

### Task 3: Rename packaging, E2E defaults, and automation paths

**Files:**
- Modify: `scripts/package-app.sh`
- Modify: `scripts/package-dmg.sh`
- Modify: `scripts/e2e-lib.sh`
- Modify: `scripts/e2e-lib.bats`
- Modify: `scripts/e2e-full-test.sh`
- Modify: `.github/workflows/ci.yml`
- Modify: `.github/workflows/release.yml`
- Modify: `.github/workflows/internal-package.yml`
- Modify: `.github/scripts/lib/project-automation.mjs`

- [ ] **Step 1: Write the failing test**

Append this regression test to `scripts/e2e-lib.bats`:

```bash
@test "e2e defaults target Wink identity" {
  run bash -lc "source '$BATS_TEST_DIRNAME/e2e-lib.sh'; printf '%s\n%s\n%s\n%s\n' \"$APP_PATH\" \"$LOG_FILE\" \"$APP_BUNDLE_ID\" \"$SHORTCUTS_FILE\""

  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *"/build/Wink.app" ]]
  [[ "${lines[1]}" == *"/.config/Wink/debug.log" ]]
  [ "${lines[2]}" = "com.wink.app" ]
  [[ "${lines[3]}" == *"/Library/Application Support/Wink/shortcuts.json" ]]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
bats scripts/e2e-lib.bats
```

Expected: FAIL because `e2e-lib.sh` still defaults to `Quickey.app`, `com.quickey.app`, and Quickey-owned log/data paths.

- [ ] **Step 3: Write minimal implementation**

Update the packaging identity in `scripts/package-app.sh`:

```bash
APP_NAME="Wink"
BUNDLE_ID="com.wink.app"
INFO_PLIST="$PROJECT_DIR/Sources/Wink/Resources/Info.plist"
SIGN_IDENTITY="${SIGN_IDENTITY:-Wink}"
```

Update `scripts/package-dmg.sh`:

```bash
APP_NAME="Wink"
INFO_PLIST="$PROJECT_DIR/Sources/Wink/Resources/Info.plist"
```

Rename the E2E constants in `scripts/e2e-lib.sh`:

```bash
APP_PATH="${E2E_APP_PATH:-$PROJECT_DIR/build/Wink.app}"
LOG_FILE="${E2E_LOG_FILE:-$HOME/.config/Wink/debug.log}"
APP_BUNDLE_ID="${E2E_BUNDLE_ID:-com.wink.app}"
SHORTCUTS_FILE="${E2E_SHORTCUTS_FILE:-$HOME/Library/Application Support/Wink/shortcuts.json}"
```

And update the dependent reads/usages:

```bash
defaults read "$APP_BUNDLE_ID" hyperKeyEnabled 2>/dev/null || echo "0"
pkill -f "Wink.app/Contents/MacOS/Wink" 2>/dev/null || true
```

Update workflow and automation paths:

```yaml
test -f build/Wink.app/Contents/MacOS/Wink
test -f build/Wink.app/Contents/Info.plist
file build/Wink.app/Contents/MacOS/Wink | grep -q "Mach-O"
```

```javascript
const runtimeSensitivePatterns = [
  /^Sources\/Wink\/Services\/AccessibilityPermissionService\.swift$/,
  /^Sources\/Wink\/Services\/AppSwitcher\.swift$/,
  /^Sources\/Wink\/Resources\/Info\.plist$/,
  // ...continue the existing list with `Sources/Wink/...`
];
```

Update tester/release instructions from `Quickey.app` to `Wink.app`, but keep actual GitHub repo URLs unchanged where the repo slug is still `Quickey`.

- [ ] **Step 4: Run test to verify it passes**

Run:

```bash
bats scripts/e2e-lib.bats
bash -n scripts/package-app.sh scripts/package-dmg.sh scripts/e2e-lib.sh scripts/e2e-full-test.sh
rg -n 'Quickey\.app|com\.quickey\.app|Application Support/Quickey|\.config/Quickey' scripts .github Tests/WinkTests
```

Expected:
- Bats passes
- `bash -n` exits 0
- the `rg` command prints no matches

- [ ] **Step 5: Commit**

```bash
git add scripts/package-app.sh scripts/package-dmg.sh scripts/e2e-lib.sh scripts/e2e-lib.bats scripts/e2e-full-test.sh .github/workflows/ci.yml .github/workflows/release.yml .github/workflows/internal-package.yml .github/scripts/lib/project-automation.mjs
git commit -m "build: rename packaging and automation to Wink"
```

### Task 4: Rename primary docs and correct issue #183 history

**Files:**
- Modify: `README.md`
- Modify: `AGENTS.md`
- Modify: `docs/README.md`
- Modify: `docs/handoff-notes.md`
- Modify: `docs/archive/issue-183-wink-rename-evaluation.md`
- Modify: `worker/src/index.ts`

- [ ] **Step 1: Write the failing documentation check**

Run this scoped grep first to capture the current stale current-state product-name hits:

```bash
rg -n 'Quickey is a macOS|Quickey Cheat Sheet|Quickey\.app in the Applications folder|com\.quickey\.app|Application Support/Quickey|\.config/Quickey|deferred as a product decision checkpoint' README.md AGENTS.md docs/README.md docs/handoff-notes.md worker/src/index.ts
```

Expected: multiple matches.

- [ ] **Step 2: Update the docs with exact replacement text**

Use `Wink` for product identity, but do **not** rewrite repo-slug URLs or absolute local checkout paths that still legitimately include `/Quickey/`.

Update README lead-in to:

```md
# Wink

Wink is a macOS menu bar app that binds global shortcuts to target apps, with Thor-like toggle behavior, fast activation, and lightweight usage insights.
```

Update the handoff note from “deferred” to “executed”:

```md
On 2026-04-20, issue #183 was executed as a clean-break rename from Quickey to Wink. The repository now uses `Wink` / `com.wink.app` / `Application Support/Wink` as the canonical product identity, with no compatibility layer for legacy Quickey paths or bundle identifiers.
```

Update the archive note’s implementation status to:

```md
## Implementation status for Issue #183

- Clean-break product rename applied.
- Bundle identifier renamed to `com.wink.app`.
- User data paths renamed to `Wink`.
- Legacy `Quickey` compatibility paths are intentionally not preserved.
```

Update the worker static copy so the product-facing title becomes `Wink Cheat Sheet`, but keep the actual GitHub repo link URL and visible slug label unchanged until the repository itself is renamed.

- [ ] **Step 3: Run the documentation check to verify it passes**

Run:

```bash
rg -n 'Quickey is a macOS|Quickey Cheat Sheet|Quickey\.app in the Applications folder|com\.quickey\.app|Application Support/Quickey|\.config/Quickey|deferred as a product decision checkpoint' README.md AGENTS.md docs/README.md docs/handoff-notes.md worker/src/index.ts
```

Expected: no matches in those files. Historical mentions in archived notes are allowed if they are clearly framed as history rather than current product identity.

- [ ] **Step 4: Commit**

```bash
git add README.md AGENTS.md docs/README.md docs/handoff-notes.md docs/archive/issue-183-wink-rename-evaluation.md worker/src/index.ts
git commit -m "docs: rename product to Wink"
```

### Task 5: Run the clean-break verification pass

**Files:**
- Modify: none

- [ ] **Step 1: Run the full test suite**

Run:

```bash
swift test
```

Expected: PASS.

- [ ] **Step 2: Run release-build verification**

Run:

```bash
swift build -c release
```

Expected: PASS, with `.build/release/Wink` produced.

- [ ] **Step 3: Run packaging verification**

Run:

```bash
bash scripts/package-app.sh
bash scripts/package-dmg.sh
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Sources/Wink/Resources/Info.plist)"
test -f build/Wink.app/Contents/MacOS/Wink
test -f build/Wink.app/Contents/Info.plist
test -f "build/Wink-${VERSION}.dmg"
```

Expected: all commands exit 0.

- [ ] **Step 4: Run the scoped clean-break grep**

Run:

```bash
rg -n 'Quickey\.app|com\.quickey\.app|Application Support/Quickey|\.config/Quickey|@testable import Quickey|name: "Quickey"|path: "Sources/Quickey"|path: "Tests/QuickeyTests"' Package.swift Sources/Wink Tests/WinkTests scripts .github README.md AGENTS.md docs/README.md docs/handoff-notes.md worker/src/index.ts
```

Expected: no matches.

- [ ] **Step 5: Record the required macOS follow-up**

Add a short validation note to the active PR description or handoff summary stating:

```md
macOS runtime validation pending under the new `Wink` identity: Accessibility, Input Monitoring, launch-at-login, event tap readiness, and packaged-app E2E must be revalidated because `com.wink.app` is a new TCC/login-item identity.
```

- [ ] **Step 6: Commit**

```bash
git add .
git commit -m "chore: verify Wink clean-break rename"
```
