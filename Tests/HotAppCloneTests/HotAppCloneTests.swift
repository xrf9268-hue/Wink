import Testing
import AppKit
import Carbon.HIToolbox
@testable import HotAppClone

// MARK: - AppShortcut

@Test
func appShortcutStoresBundleIdentifier() {
    let shortcut = AppShortcut(
        appName: "Slack",
        bundleIdentifier: "com.tinyspeck.slackmacgap",
        keyEquivalent: "s",
        modifierFlags: ["command", "option", "control", "shift"]
    )

    #expect(shortcut.bundleIdentifier == "com.tinyspeck.slackmacgap")
}

// MARK: - EventTapManager lifecycle

@Suite("EventTapManager lifecycle")
struct EventTapManagerLifecycleTests {
    @Test @MainActor
    func isRunningStartsFalse() {
        let manager = EventTapManager()
        #expect(manager.isRunning == false)
    }

    @Test @MainActor
    func stopIsIdempotentWhenNotRunning() {
        let manager = EventTapManager()
        manager.stop()
        manager.stop()
        #expect(manager.isRunning == false)
    }
}

// MARK: - KeyMatcher

@Suite("KeyMatcher")
struct KeyMatcherTests {
    let matcher = KeyMatcher()

    @Test
    func triggerForShortcutProducesCorrectKeyCode() {
        let shortcut = AppShortcut(
            appName: "Test", bundleIdentifier: "com.test",
            keyEquivalent: "s", modifierFlags: ["command"]
        )
        let trigger = matcher.trigger(for: shortcut)
        #expect(trigger.keyCode == CGKeyCode(kVK_ANSI_S))
    }

    @Test
    func triggerForShortcutIsCaseInsensitive() {
        let lower = AppShortcut(appName: "T", bundleIdentifier: "com.t", keyEquivalent: "s", modifierFlags: ["command"])
        let upper = AppShortcut(appName: "T", bundleIdentifier: "com.t", keyEquivalent: "S", modifierFlags: ["command"])
        #expect(matcher.trigger(for: lower) == matcher.trigger(for: upper))
    }

    @Test @MainActor
    func matchesReturnsTrueForMatchingKeyPress() {
        let shortcut = AppShortcut(
            appName: "Test", bundleIdentifier: "com.test",
            keyEquivalent: "a", modifierFlags: ["command", "option"]
        )
        let keyPress = EventTapManager.KeyPress(
            keyCode: CGKeyCode(kVK_ANSI_A),
            modifiers: [.command, .option]
        )
        #expect(matcher.matches(keyPress, shortcut: shortcut))
    }

    @Test @MainActor
    func matchesReturnsFalseForDifferentKey() {
        let shortcut = AppShortcut(
            appName: "Test", bundleIdentifier: "com.test",
            keyEquivalent: "a", modifierFlags: ["command"]
        )
        let keyPress = EventTapManager.KeyPress(
            keyCode: CGKeyCode(kVK_ANSI_B),
            modifiers: [.command]
        )
        #expect(!matcher.matches(keyPress, shortcut: shortcut))
    }

    @Test @MainActor
    func matchesReturnsFalseForDifferentModifiers() {
        let shortcut = AppShortcut(
            appName: "Test", bundleIdentifier: "com.test",
            keyEquivalent: "a", modifierFlags: ["command", "shift"]
        )
        let keyPress = EventTapManager.KeyPress(
            keyCode: CGKeyCode(kVK_ANSI_A),
            modifiers: [.command]
        )
        #expect(!matcher.matches(keyPress, shortcut: shortcut))
    }

    @Test
    func buildIndexContainsAllShortcuts() {
        let shortcuts = [
            AppShortcut(appName: "A", bundleIdentifier: "com.a", keyEquivalent: "a", modifierFlags: ["command"]),
            AppShortcut(appName: "B", bundleIdentifier: "com.b", keyEquivalent: "b", modifierFlags: ["option"]),
            AppShortcut(appName: "C", bundleIdentifier: "com.c", keyEquivalent: "c", modifierFlags: ["control"]),
        ]
        let index = matcher.buildIndex(for: shortcuts)
        #expect(index.count == 3)
    }

    @Test @MainActor
    func buildIndexEnablesO1Lookup() {
        let shortcut = AppShortcut(
            appName: "Terminal", bundleIdentifier: "com.apple.Terminal",
            keyEquivalent: "t", modifierFlags: ["command", "option"]
        )
        let index = matcher.buildIndex(for: [shortcut])
        let keyPress = EventTapManager.KeyPress(
            keyCode: CGKeyCode(kVK_ANSI_T),
            modifiers: [.command, .option]
        )
        let key = matcher.trigger(for: keyPress)
        #expect(index[key]?.bundleIdentifier == "com.apple.Terminal")
    }

    @Test @MainActor
    func hyperStyleShortcutMatchesAllFourModifiers() {
        let shortcut = AppShortcut(
            appName: "Hyper", bundleIdentifier: "com.hyper",
            keyEquivalent: "h", modifierFlags: ["command", "option", "control", "shift"]
        )
        let keyPress = EventTapManager.KeyPress(
            keyCode: CGKeyCode(kVK_ANSI_H),
            modifiers: [.command, .option, .control, .shift]
        )
        #expect(matcher.matches(keyPress, shortcut: shortcut))
    }

    @Test @MainActor
    func hyperStyleDoesNotMatchSubsetOfModifiers() {
        let shortcut = AppShortcut(
            appName: "Hyper", bundleIdentifier: "com.hyper",
            keyEquivalent: "h", modifierFlags: ["command", "option", "control", "shift"]
        )
        let threeModifiers = EventTapManager.KeyPress(
            keyCode: CGKeyCode(kVK_ANSI_H),
            modifiers: [.command, .option, .control]
        )
        #expect(!matcher.matches(threeModifiers, shortcut: shortcut))
    }

    @Test @MainActor
    func hyperStyleIndexLookupWorks() {
        let shortcut = AppShortcut(
            appName: "Hyper", bundleIdentifier: "com.hyper",
            keyEquivalent: "j", modifierFlags: ["command", "option", "control", "shift"]
        )
        let index = matcher.buildIndex(for: [shortcut])
        let keyPress = EventTapManager.KeyPress(
            keyCode: CGKeyCode(kVK_ANSI_J),
            modifiers: [.command, .option, .control, .shift]
        )
        let key = matcher.trigger(for: keyPress)
        #expect(index[key]?.bundleIdentifier == "com.hyper")
    }

    @Test
    func modifierOrderDoesNotAffectTrigger() {
        let ordered = AppShortcut(appName: "A", bundleIdentifier: "com.a", keyEquivalent: "a", modifierFlags: ["command", "option", "shift"])
        let reversed = AppShortcut(appName: "A", bundleIdentifier: "com.a", keyEquivalent: "a", modifierFlags: ["shift", "option", "command"])
        #expect(matcher.trigger(for: ordered) == matcher.trigger(for: reversed))
    }

    @Test @MainActor
    func functionModifierMatchesCorrectly() {
        let shortcut = AppShortcut(
            appName: "FnApp", bundleIdentifier: "com.fn",
            keyEquivalent: "f1", modifierFlags: ["function"]
        )
        let keyPress = EventTapManager.KeyPress(
            keyCode: CGKeyCode(kVK_F1),
            modifiers: [.function]
        )
        #expect(matcher.matches(keyPress, shortcut: shortcut))
    }

    @Test
    func unknownKeyEquivalentReturnsMaxKeyCode() {
        let shortcut = AppShortcut(
            appName: "X", bundleIdentifier: "com.x",
            keyEquivalent: "§", modifierFlags: ["command"]
        )
        let trigger = matcher.trigger(for: shortcut)
        #expect(trigger.keyCode == CGKeyCode(UInt16.max))
    }

    @Test
    func specialKeysMapCorrectly() {
        let spaceShortcut = AppShortcut(appName: "S", bundleIdentifier: "com.s", keyEquivalent: "space", modifierFlags: ["command"])
        #expect(matcher.trigger(for: spaceShortcut).keyCode == CGKeyCode(kVK_Space))

        let returnShortcut = AppShortcut(appName: "R", bundleIdentifier: "com.r", keyEquivalent: "return", modifierFlags: ["command"])
        let enterShortcut = AppShortcut(appName: "E", bundleIdentifier: "com.e", keyEquivalent: "enter", modifierFlags: ["command"])
        #expect(matcher.trigger(for: returnShortcut).keyCode == matcher.trigger(for: enterShortcut).keyCode)
    }
}

// MARK: - ShortcutValidator

@Suite("ShortcutValidator")
struct ShortcutValidatorTests {
    let validator = ShortcutValidator()

    @Test
    func detectsConflictWithSameKeyAndModifiers() {
        let existing = AppShortcut(appName: "A", bundleIdentifier: "com.a", keyEquivalent: "s", modifierFlags: ["command", "option"])
        let candidate = AppShortcut(appName: "B", bundleIdentifier: "com.b", keyEquivalent: "s", modifierFlags: ["command", "option"])
        let conflict = validator.conflict(for: candidate, in: [existing])
        #expect(conflict != nil)
        #expect(conflict?.existingShortcut.bundleIdentifier == "com.a")
    }

    @Test
    func noConflictWithDifferentKey() {
        let existing = AppShortcut(appName: "A", bundleIdentifier: "com.a", keyEquivalent: "s", modifierFlags: ["command"])
        let candidate = AppShortcut(appName: "B", bundleIdentifier: "com.b", keyEquivalent: "t", modifierFlags: ["command"])
        #expect(validator.conflict(for: candidate, in: [existing]) == nil)
    }

    @Test
    func noConflictWithDifferentModifiers() {
        let existing = AppShortcut(appName: "A", bundleIdentifier: "com.a", keyEquivalent: "s", modifierFlags: ["command"])
        let candidate = AppShortcut(appName: "B", bundleIdentifier: "com.b", keyEquivalent: "s", modifierFlags: ["command", "shift"])
        #expect(validator.conflict(for: candidate, in: [existing]) == nil)
    }

    @Test
    func conflictDetectionIsCaseInsensitive() {
        let existing = AppShortcut(appName: "A", bundleIdentifier: "com.a", keyEquivalent: "S", modifierFlags: ["Command"])
        let candidate = AppShortcut(appName: "B", bundleIdentifier: "com.b", keyEquivalent: "s", modifierFlags: ["command"])
        #expect(validator.conflict(for: candidate, in: [existing]) != nil)
    }

    @Test
    func noConflictWithSelf() {
        let shortcut = AppShortcut(appName: "A", bundleIdentifier: "com.a", keyEquivalent: "s", modifierFlags: ["command"])
        #expect(validator.conflict(for: shortcut, in: [shortcut]) == nil)
    }

    @Test
    func noConflictInEmptyList() {
        let candidate = AppShortcut(appName: "A", bundleIdentifier: "com.a", keyEquivalent: "s", modifierFlags: ["command"])
        #expect(validator.conflict(for: candidate, in: []) == nil)
    }

    @Test
    func hyperStyleConflictDetected() {
        let existing = AppShortcut(appName: "A", bundleIdentifier: "com.a", keyEquivalent: "h", modifierFlags: ["command", "option", "control", "shift"])
        let candidate = AppShortcut(appName: "B", bundleIdentifier: "com.b", keyEquivalent: "h", modifierFlags: ["shift", "control", "option", "command"])
        #expect(validator.conflict(for: candidate, in: [existing]) != nil)
    }

    @Test
    func hyperVsTripleModifierNoConflict() {
        let hyper = AppShortcut(appName: "A", bundleIdentifier: "com.a", keyEquivalent: "h", modifierFlags: ["command", "option", "control", "shift"])
        let triple = AppShortcut(appName: "B", bundleIdentifier: "com.b", keyEquivalent: "h", modifierFlags: ["command", "option", "control"])
        #expect(validator.conflict(for: triple, in: [hyper]) == nil)
    }
}

// MARK: - KeySymbolMapper

@Suite("KeySymbolMapper")
struct KeySymbolMapperTests {
    let mapper = KeySymbolMapper()

    @Test
    func mapsLetterKeyCodes() {
        #expect(mapper.keyEquivalent(for: CGKeyCode(kVK_ANSI_A)) == "a")
        #expect(mapper.keyEquivalent(for: CGKeyCode(kVK_ANSI_Z)) == "z")
    }

    @Test
    func mapsNumberKeyCodes() {
        #expect(mapper.keyEquivalent(for: CGKeyCode(kVK_ANSI_0)) == "0")
        #expect(mapper.keyEquivalent(for: CGKeyCode(kVK_ANSI_9)) == "9")
    }

    @Test
    func mapsSpecialKeys() {
        #expect(mapper.keyEquivalent(for: CGKeyCode(kVK_Space)) == "space")
        #expect(mapper.keyEquivalent(for: CGKeyCode(kVK_Tab)) == "tab")
        #expect(mapper.keyEquivalent(for: CGKeyCode(kVK_UpArrow)) == "up")
    }

    @Test
    func returnsNilForUnknownKeyCode() {
        #expect(mapper.keyEquivalent(for: CGKeyCode(999)) == nil)
    }

    @Test
    func roundTripsWithKeyMatcher() {
        // Every code in codeToKeyEquivalent should map back to the same code
        for (code, key) in KeyMatcher.codeToKeyEquivalent {
            let mappedCode = KeyMatcher.keyEquivalentToCode[key]
            #expect(mappedCode == code, "Round-trip failed for key '\(key)' code \(code)")
        }
    }
}

// MARK: - UsageTracker

@Suite("UsageTracker")
struct UsageTrackerTests {
    @Test
    func recordAndQueryUsage() async {
        let tracker = UsageTracker(databasePath: ":memory:")
        let id = UUID()

        await tracker.recordUsage(shortcutId: id)
        await tracker.recordUsage(shortcutId: id)

        let counts = await tracker.usageCounts(days: 1)
        #expect(counts[id] == 2)
    }

    @Test
    func totalSwitchesAggregatesAll() async {
        let tracker = UsageTracker(databasePath: ":memory:")
        let id1 = UUID()
        let id2 = UUID()

        await tracker.recordUsage(shortcutId: id1)
        await tracker.recordUsage(shortcutId: id1)
        await tracker.recordUsage(shortcutId: id2)

        let total = await tracker.totalSwitches(days: 1)
        #expect(total == 3)
    }

    @Test
    func deleteRemovesUsage() async {
        let tracker = UsageTracker(databasePath: ":memory:")
        let id = UUID()

        await tracker.recordUsage(shortcutId: id)
        await tracker.deleteUsage(shortcutId: id)

        let counts = await tracker.usageCounts(days: 1)
        #expect(counts[id] == nil)
    }

    @Test
    func dailyCountsReturnsPerDayBreakdown() async {
        let tracker = UsageTracker(databasePath: ":memory:")
        let id = UUID()

        await tracker.recordUsage(shortcutId: id)

        let daily = await tracker.dailyCounts(days: 1)
        let entries = daily[id.uuidString]
        #expect(entries != nil)
        #expect(entries?.isEmpty == false)
    }
}
