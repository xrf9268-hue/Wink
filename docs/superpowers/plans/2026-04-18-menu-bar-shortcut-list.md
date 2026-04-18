# Menu Bar Shortcut List Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show every saved Quickey shortcut at the top of the menu bar dropdown as a read-only custom row with app icon, app name, running-state dot, disabled marker, and shortcut text, while keeping the existing static menu items intact.

**Architecture:** Keep `MenuBarController` as the single owner of the AppKit menu, but split the new feature into a small presentation builder plus a dedicated custom row view. Rebuild the dynamic shortcut section on each `menuWillOpen(_:)` from `ShortcutStore.shortcuts` and a one-shot running-bundle snapshot, mark dynamic items so they can be removed deterministically, and leave `Settings`, `Launch at Login`, and `Quit` below a dedicated divider.

**Tech Stack:** Swift 6, AppKit, `NSMenu` / `NSMenuItem`, `NSWorkspace`, Swift Testing

---

## Inputs

- Spec: [2026-04-18-menu-bar-shortcut-list-design.md](/home/yvan/developer/Quickey/docs/superpowers/specs/2026-04-18-menu-bar-shortcut-list-design.md)
- Existing menu owner: [MenuBarController.swift](/home/yvan/developer/Quickey/Sources/Quickey/UI/MenuBarController.swift)
- Startup wiring: [AppController.swift](/home/yvan/developer/Quickey/Sources/Quickey/AppController.swift)
- Existing menu tests: [MenuBarLaunchAtLoginPresentationTests.swift](/home/yvan/developer/Quickey/Tests/QuickeyTests/MenuBarLaunchAtLoginPresentationTests.swift)

## File Map

**Create:**

- `Sources/Quickey/UI/MenuBarShortcutItemPresentation.swift`
  Purpose: convert `AppShortcut` plus a running-bundle snapshot into deterministic menu-row presentation data, including the empty placeholder row.
- `Sources/Quickey/UI/MenuBarShortcutRowView.swift`
  Purpose: render the compact custom AppKit row used inside `NSMenuItem.view`.
- `Tests/QuickeyTests/MenuBarShortcutItemPresentationTests.swift`
  Purpose: lock down ordering, running-dot semantics, disabled labeling, and empty-state behavior.
- `Tests/QuickeyTests/MenuBarControllerShortcutMenuTests.swift`
  Purpose: lock down dynamic-section rebuild behavior, duplicate prevention, and the `menuWillOpen(_:)` refresh path.

**Modify:**

- `Sources/Quickey/UI/MenuBarController.swift`
  Purpose: inject `ShortcutStore`, compute running bundles on open, rebuild the dynamic section, and keep the existing static actions stable below the shortcut section.
- `Sources/Quickey/AppController.swift`
  Purpose: pass the shared `ShortcutStore` into `MenuBarController` so the menu can read the saved shortcut list.

## Constraints To Preserve

- Dynamic shortcut rows are informational only; they must not trigger app switching or settings actions.
- Shortcut order must match `ShortcutStore.shortcuts`; do not add a second sorting rule.
- The green dot means “at least one running instance exists for this bundle,” not “frontmost” or “Quickey owns the activation.”
- Disabled shortcuts stay visible with muted styling plus an explicit `disabled` label.
- Repeated menu opens must not accumulate duplicate dynamic rows or duplicate dividers.
- AppKit layout and icon rendering must be manually validated on macOS before claiming completion; Linux-only inspection is insufficient.

## Task Plan

### Task 1: Freeze The Shortcut Row Presentation Rules

**Files:**

- Create: `Sources/Quickey/UI/MenuBarShortcutItemPresentation.swift`
- Create: `Tests/QuickeyTests/MenuBarShortcutItemPresentationTests.swift`
- Reference: `Sources/Quickey/Models/AppShortcut.swift`
- Reference: `Sources/Quickey/Models/RecordedShortcut.swift`

- [ ] **Step 1: Write the failing presentation tests**

Create `Tests/QuickeyTests/MenuBarShortcutItemPresentationTests.swift` with a focused `@Suite` that verifies:

```swift
import Testing
@testable import Quickey

@Suite("MenuBar shortcut item presentation")
struct MenuBarShortcutItemPresentationTests {
    @Test
    func preservesShortcutOrderAndMarksRunningBundles() {
        let shortcuts = [
            AppShortcut(appName: "Safari", bundleIdentifier: "com.apple.Safari", keyEquivalent: "s", modifierFlags: ["control", "option"]),
            AppShortcut(appName: "IINA", bundleIdentifier: "com.colliderli.iina", keyEquivalent: "i", modifierFlags: ["control", "option"], isEnabled: false),
        ]

        let presentations = MenuBarShortcutItemPresentation.build(
            from: shortcuts,
            runningBundleIdentifiers: ["com.apple.Safari"]
        )

        #expect(presentations.map(\.titleText) == ["Safari", "IINA"])
        #expect(presentations.map(\.isRunning) == [true, false])
        #expect(presentations.map(\.statusText) == [nil, "disabled"])
    }

    @Test
    func returnsPlaceholderWhenShortcutListIsEmpty() {
        let presentations = MenuBarShortcutItemPresentation.build(
            from: [],
            runningBundleIdentifiers: []
        )

        #expect(presentations.count == 1)
        #expect(presentations[0].isPlaceholder == true)
        #expect(presentations[0].titleText == "No shortcuts configured")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run on a macOS host:

```bash
swift test --filter MenuBarShortcutItemPresentationTests
```

Expected: FAIL because `MenuBarShortcutItemPresentation` and its `build` helper do not exist yet.

- [ ] **Step 3: Write the minimal presentation builder**

Create `Sources/Quickey/UI/MenuBarShortcutItemPresentation.swift`:

```swift
import Foundation

struct MenuBarShortcutItemPresentation: Equatable {
    let bundleIdentifier: String?
    let titleText: String
    let shortcutText: String?
    let statusText: String?
    let isEnabled: Bool
    let isRunning: Bool
    let isPlaceholder: Bool

    static func build(
        from shortcuts: [AppShortcut],
        runningBundleIdentifiers: Set<String>
    ) -> [MenuBarShortcutItemPresentation] {
        guard !shortcuts.isEmpty else {
            return [
                MenuBarShortcutItemPresentation(
                    bundleIdentifier: nil,
                    titleText: "No shortcuts configured",
                    shortcutText: nil,
                    statusText: nil,
                    isEnabled: false,
                    isRunning: false,
                    isPlaceholder: true
                )
            ]
        }

        return shortcuts.map { shortcut in
            MenuBarShortcutItemPresentation(
                bundleIdentifier: shortcut.bundleIdentifier,
                titleText: shortcut.appName,
                shortcutText: shortcut.displayText,
                statusText: shortcut.isEnabled ? nil : "disabled",
                isEnabled: shortcut.isEnabled,
                isRunning: runningBundleIdentifiers.contains(shortcut.bundleIdentifier),
                isPlaceholder: false
            )
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run on a macOS host:

```bash
swift test --filter MenuBarShortcutItemPresentationTests
```

Expected: PASS. If you are implementing from Linux and cannot run the macOS-targeted test suite, record this verification as pending instead of claiming success.

- [ ] **Step 5: Commit the presentation-model checkpoint**

```bash
git add Sources/Quickey/UI/MenuBarShortcutItemPresentation.swift Tests/QuickeyTests/MenuBarShortcutItemPresentationTests.swift
git commit -m "test: add menu bar shortcut presentation rules"
```

### Task 2: Freeze Dynamic Section Rebuild Behavior

**Files:**

- Create: `Tests/QuickeyTests/MenuBarControllerShortcutMenuTests.swift`
- Modify: `Sources/Quickey/UI/MenuBarController.swift`
- Reference: `Sources/Quickey/UI/MenuBarShortcutItemPresentation.swift`

- [ ] **Step 1: Write the failing menu-composition tests**

Create `Tests/QuickeyTests/MenuBarControllerShortcutMenuTests.swift` with a `@MainActor` suite that builds a local `NSMenu`, seeds the existing static items, and asserts that rebuilding the shortcut section is deterministic:

```swift
import AppKit
import Testing
@testable import Quickey

@Suite("MenuBarController shortcut section")
struct MenuBarControllerShortcutMenuTests {
    @Test @MainActor
    func rebuildShortcutSectionInsertsRowsAboveStaticItemsWithoutDuplication() {
        let controller = MenuBarController(
            shortcutStore: ShortcutStore(),
            onOpenSettings: {},
            onQuit: {},
            runningBundleIdentifiers: { [] }
        )

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Settings", action: nil, keyEquivalent: ""))
        let loginItem = NSMenuItem(title: "Launch at Login", action: nil, keyEquivalent: "")
        menu.addItem(loginItem)
        menu.addItem(NSMenuItem(title: "Quit", action: nil, keyEquivalent: ""))

        let presentations = [
            MenuBarShortcutItemPresentation(
                bundleIdentifier: "com.apple.Safari",
                titleText: "Safari",
                shortcutText: "⌃⌥S",
                statusText: nil,
                isEnabled: true,
                isRunning: true,
                isPlaceholder: false
            )
        ]

        controller.rebuildShortcutSection(in: menu, presentations: presentations)
        controller.rebuildShortcutSection(in: menu, presentations: presentations)

        #expect(menu.items.filter { $0.representedObject as? String == MenuBarController.shortcutRowMarker }.count == 1)
        #expect(menu.items.filter { $0.representedObject as? String == MenuBarController.shortcutDividerMarker }.count == 1)
        #expect(menu.items.last?.title == "Quit")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run on a macOS host:

```bash
swift test --filter MenuBarControllerShortcutMenuTests
```

Expected: FAIL because `MenuBarController` does not yet accept `ShortcutStore`, expose running-bundle injection, or provide rebuild markers/helpers.

- [ ] **Step 3: Implement deterministic section rebuild**

Modify `Sources/Quickey/UI/MenuBarController.swift` so it:

- accepts `shortcutStore: ShortcutStore`
- accepts `runningBundleIdentifiers: @escaping @MainActor () -> Set<String>` with a live default using `NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)`
- defines internal markers for shortcut rows and the shortcut divider
- exposes an internal `rebuildShortcutSection(in:presentations:)` helper for tests
- removes all existing marked items before inserting the new dynamic section at the top of the menu

Implementation sketch:

```swift
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    static let shortcutRowMarker = "menuBar.shortcutRow"
    static let shortcutDividerMarker = "menuBar.shortcutDivider"

    private let shortcutStore: ShortcutStore
    private let runningBundleIdentifiers: @MainActor () -> Set<String>

    func rebuildShortcutSection(in menu: NSMenu, presentations: [MenuBarShortcutItemPresentation]) {
        for item in menu.items.reversed() {
            guard let marker = item.representedObject as? String else { continue }
            guard marker == Self.shortcutRowMarker || marker == Self.shortcutDividerMarker else { continue }
            menu.removeItem(item)
        }

        var insertionIndex = 0
        for presentation in presentations {
            let item = NSMenuItem(title: presentation.titleText, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.representedObject = Self.shortcutRowMarker
            menu.insertItem(item, at: insertionIndex)
            insertionIndex += 1
        }

        let divider = NSMenuItem.separator()
        divider.representedObject = Self.shortcutDividerMarker
        menu.insertItem(divider, at: insertionIndex)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run on a macOS host:

```bash
swift test --filter MenuBarControllerShortcutMenuTests
```

Expected: PASS. The helper may still use placeholder plain menu items at this stage; the next task will swap in the real custom row view while keeping the composition tests green.

- [ ] **Step 5: Commit the rebuild-behavior checkpoint**

```bash
git add Sources/Quickey/UI/MenuBarController.swift Tests/QuickeyTests/MenuBarControllerShortcutMenuTests.swift
git commit -m "test: lock down menu bar shortcut section rebuilds"
```

### Task 3: Render Custom Rows And Wire The Live Refresh Path

**Files:**

- Create: `Sources/Quickey/UI/MenuBarShortcutRowView.swift`
- Modify: `Sources/Quickey/UI/MenuBarController.swift`
- Modify: `Sources/Quickey/AppController.swift`
- Modify: `Tests/QuickeyTests/MenuBarControllerShortcutMenuTests.swift`
- Reference: `Sources/Quickey/UI/SharedComponents.swift`

- [ ] **Step 1: Write the failing integration-style menu tests**

Extend `Tests/QuickeyTests/MenuBarControllerShortcutMenuTests.swift` with `@MainActor` tests that drive `menuWillOpen(_:)` through the real `ShortcutStore` and verify the live refresh path:

```swift
@Test @MainActor
func menuWillOpenBuildsCustomRowsFromShortcutStoreAndRunningSnapshot() {
    let store = ShortcutStore()
    store.replaceAll(with: [
        AppShortcut(appName: "Safari", bundleIdentifier: "com.apple.Safari", keyEquivalent: "s", modifierFlags: ["control", "option"]),
        AppShortcut(appName: "IINA", bundleIdentifier: "com.colliderli.iina", keyEquivalent: "i", modifierFlags: ["control", "option"], isEnabled: false),
    ])

    let controller = MenuBarController(
        shortcutStore: store,
        onOpenSettings: {},
        onQuit: {},
        runningBundleIdentifiers: { ["com.apple.Safari"] }
    )

    let menu = controller.installMenuForTesting()
    controller.menuWillOpen(menu)

    let shortcutItems = menu.items.filter {
        $0.representedObject as? String == MenuBarController.shortcutRowMarker
    }

    #expect(shortcutItems.count == 2)
    #expect(shortcutItems.allSatisfy { $0.view is MenuBarShortcutRowView })
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run on a macOS host:

```bash
swift test --filter MenuBarControllerShortcutMenuTests
```

Expected: FAIL because the menu still uses placeholder plain `NSMenuItem` rows and the controller is not yet building rows from the live store during `menuWillOpen(_:)`.

- [ ] **Step 3: Implement the custom row view and live menu refresh**

Create `Sources/Quickey/UI/MenuBarShortcutRowView.swift` and finish the controller integration:

```swift
import AppKit

final class MenuBarShortcutRowView: NSView {
    init(presentation: MenuBarShortcutItemPresentation) {
        super.init(frame: .zero)

        let iconView = NSImageView(image: AppIconCache.icon(for: presentation.bundleIdentifier ?? "") ?? NSWorkspace.shared.icon(for: .application))
        let nameField = NSTextField(labelWithString: presentation.titleText)
        let shortcutField = NSTextField(labelWithString: presentation.shortcutText ?? "")

        // Build one-line horizontal layout.
        // Hide the running dot when presentation.isRunning == false.
        // Show the disabled label when presentation.statusText != nil.
        // Mutate text colors for disabled rows without making the row interactive.
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}
```

Then modify `Sources/Quickey/UI/MenuBarController.swift` to:

- hold the injected `ShortcutStore`
- build `MenuBarShortcutItemPresentation.build(from:runningBundleIdentifiers:)` inside `menuWillOpen(_:)`
- call `rebuildShortcutSection(in:presentations:)`
- replace placeholder plain items with `NSMenuItem` instances whose `view` is `MenuBarShortcutRowView`
- keep the marker-based removal logic so repeated opens stay deterministic
- keep `Settings`, `Launch at Login`, and `Quit` below the shortcut divider

Update `Sources/Quickey/AppController.swift` so the live `MenuBarController` receives the shared `shortcutStore`:

```swift
private lazy var menuBarController = MenuBarController(
    shortcutStore: shortcutStore,
    onOpenSettings: { [weak self] in self?.openSettings() },
    onQuit: { NSApplication.shared.terminate(nil) }
)
```

- [ ] **Step 4: Run targeted tests and the full suite**

Run on a macOS host:

```bash
swift test --filter MenuBarControllerShortcutMenuTests
swift test
```

Expected:

- `MenuBarControllerShortcutMenuTests`: PASS
- full `swift test`: PASS

If you are implementing from Linux or another non-macOS host, do not claim these commands passed. Record build/test verification as pending for a macOS machine.

- [ ] **Step 5: Commit the feature implementation**

```bash
git add Sources/Quickey/AppController.swift Sources/Quickey/UI/MenuBarController.swift Sources/Quickey/UI/MenuBarShortcutRowView.swift Tests/QuickeyTests/MenuBarControllerShortcutMenuTests.swift
git commit -m "feat: show shortcuts in the menu bar menu"
```

### Task 4: Verify On macOS And Record Pending Work Truthfully

**Files:**

- Modify if needed: `docs/handoff-notes.md`

- [ ] **Step 1: Run local build/test/package verification on macOS**

```bash
swift build
swift test
swift build -c release
```

Expected: PASS on a macOS host.

- [ ] **Step 2: Validate the menu behavior manually on macOS**

Check all of the following against a real menu bar session:

- shortcut rows appear above `Settings`
- enabled and disabled rows are visually distinct
- the green dot appears for running bundles only
- repeated menu opens do not duplicate rows or separators
- an empty shortcut store shows `No shortcuts configured`

- [ ] **Step 3: Validate a mixed shortcut fixture**

Use at least one enabled shortcut for a currently running app and one disabled shortcut for a not-running app. Confirm the menu still preserves the saved order rather than grouping by status.

- [ ] **Step 4: Record truthfully if macOS validation did not happen**

If you are not on macOS, or if you could not run the visual validation:

- update the final work summary to say macOS UI validation is pending
- do not claim the feature is complete from Linux-only inspection
- if you maintain `docs/handoff-notes.md` for this branch, add a brief note that issue #180 implementation exists but menu rendering verification is still pending on macOS

- [ ] **Step 5: Commit only if documentation changed during verification**

```bash
git add docs/handoff-notes.md
git commit -m "docs: note menu bar shortcut list validation status"
```

Skip this commit if verification produced no documentation changes.
