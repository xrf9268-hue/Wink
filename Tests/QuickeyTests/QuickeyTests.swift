import Testing
import AppKit
import Carbon.HIToolbox
@testable import Quickey

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

// MARK: - EventTapManager registered shortcuts & hyper key

@Suite("EventTapManager state management")
struct EventTapManagerStateTests {
    @Test @MainActor
    func updateRegisteredShortcutsStoresKeyPresses() {
        let manager = EventTapManager()
        let keyPresses: Set<KeyPress> = [
            KeyPress(keyCode: CGKeyCode(kVK_ANSI_A), modifiers: [.command]),
            KeyPress(keyCode: CGKeyCode(kVK_ANSI_B), modifiers: [.option]),
        ]
        // Should not crash when no tap is running (box is nil)
        manager.updateRegisteredShortcuts(keyPresses)
    }

    @Test @MainActor
    func setHyperKeyEnabledDoesNotCrashWithoutTap() {
        let manager = EventTapManager()
        manager.setHyperKeyEnabled(true)
        manager.setHyperKeyEnabled(false)
    }

    @Test @MainActor
    func stopClearsState() {
        let manager = EventTapManager()
        manager.onKeyPress = { _ in true }
        manager.stop()
        #expect(manager.isRunning == false)
    }
}

// MARK: - EventTapManager debounce

@Suite("EventTapManager debounce")
struct EventTapManagerDebounceTests {
    @Test @MainActor
    func sameKeyPressWithinDebounceIntervalIsSkipped() {
        let manager = EventTapManager()
        var callCount = 0
        manager.onKeyPress = { _ in
            callCount += 1
            return true
        }
        let keyPress = KeyPress(keyCode: CGKeyCode(kVK_ANSI_S), modifiers: [.command])

        // First call should go through
        manager.handleAsync(keyPress)
        #expect(callCount == 1)

        // Second call with same key within 200ms should be debounced
        manager.handleAsync(keyPress)
        #expect(callCount == 1)
    }

    @Test @MainActor
    func differentKeyPressesAreNotDebounced() {
        let manager = EventTapManager()
        var callCount = 0
        manager.onKeyPress = { _ in
            callCount += 1
            return true
        }
        let keyA = KeyPress(keyCode: CGKeyCode(kVK_ANSI_A), modifiers: [.command])
        let keyB = KeyPress(keyCode: CGKeyCode(kVK_ANSI_B), modifiers: [.command])

        manager.handleAsync(keyA)
        #expect(callCount == 1)

        // Different key should not be debounced
        manager.handleAsync(keyB)
        #expect(callCount == 2)
    }

    @Test @MainActor
    func sameKeyWithDifferentModifiersIsNotDebounced() {
        let manager = EventTapManager()
        var callCount = 0
        manager.onKeyPress = { _ in
            callCount += 1
            return true
        }
        let cmdA = KeyPress(keyCode: CGKeyCode(kVK_ANSI_A), modifiers: [.command])
        let optA = KeyPress(keyCode: CGKeyCode(kVK_ANSI_A), modifiers: [.option])

        manager.handleAsync(cmdA)
        manager.handleAsync(optA)
        #expect(callCount == 2)
    }
}

// MARK: - EventTapManager delivery

@Suite("EventTapManager delivery")
struct EventTapManagerDeliveryTests {
    @Test
    func matchedShortcutHandlerCanBeInvokedFromBackgroundThread() async {
        let keyPress = KeyPress(keyCode: CGKeyCode(kVK_ANSI_Q), modifiers: [.command])
        let receivedKeyPress: KeyPress = await withCheckedContinuation { (continuation: CheckedContinuation<KeyPress, Never>) in
            let handler = MatchedShortcutDelivery.makeHandler { deliveredKeyPress in
                MainActor.preconditionIsolated()
                continuation.resume(returning: deliveredKeyPress)
            }

            DispatchQueue.global().async {
                handler(keyPress)
            }
        }

        #expect(receivedKeyPress == keyPress)
    }

    @Test
    func disabledTapEventRequestsReenable() {
        let event = makeKeyEvent(CGKeyCode(kVK_ANSI_A), modifiers: [], keyDown: true)
        let box = EventTapBox()
        let counter = SendableCounter()
        box.reenableTap = { counter.value += 1 }

        let result = handleEventTapEvent(type: .tapDisabledByTimeout, event: event, box: box)

        #expect(result != nil)
        #expect(counter.value == 1)
    }

    @Test
    func disabledTapDiagnosticsIncludeMostRecentShortcutContext() throws {
        let keyPress = KeyPress(keyCode: CGKeyCode(kVK_ANSI_A), modifiers: [.command])
        let event = makeKeyEvent(keyPress.keyCode, modifiers: keyPress.modifiers, keyDown: true)
        let box = EventTapBox()
        box.registeredShortcuts = [keyPress]

        let diagnostics = LockedValue<EventTapDiagnosticsSnapshot?>(nil)
        box.onTapDisabled = { snapshot in
            diagnostics.value = snapshot
        }

        let keyDownResult = handleEventTapEvent(type: .keyDown, event: event, box: box)
        #expect(keyDownResult == nil)

        let timeoutResult = handleEventTapEvent(type: .tapDisabledByTimeout, event: event, box: box)
        #expect(timeoutResult != nil)

        let snapshot = try #require(diagnostics.value)
        #expect(snapshot.reason == .tapDisabledByTimeout)
        #expect(snapshot.disableCount == 1)
        #expect(snapshot.lastEventType == .keyDown)
        #expect(snapshot.lastKeyCode == keyPress.keyCode)
        #expect(snapshot.lastModifierFlags == keyPress.modifiers.rawValue)
        #expect(snapshot.lastShortcutWasSwallowed == true)
        #expect(snapshot.lastHyperInjected == false)
        #expect(snapshot.registeredShortcutCount == 1)
        #expect(snapshot.hyperKeyEnabled == false)
        #expect(snapshot.hyperKeyHeld == false)
    }

    @Test
    func hyperKeyPressAndReleaseToggleHeldState() {
        let keyDown = makeKeyEvent(HyperKeyService.f19KeyCode, modifiers: [], keyDown: true)
        let keyUp = makeKeyEvent(HyperKeyService.f19KeyCode, modifiers: [], keyDown: false)
        let box = EventTapBox()
        box.setHyperKey(enabled: true)

        let downResult = handleEventTapEvent(type: .keyDown, event: keyDown, box: box)
        #expect(downResult == nil)
        #expect(box.isHyperHeld == true)

        let upResult = handleEventTapEvent(type: .keyUp, event: keyUp, box: box)
        #expect(upResult == nil)
        #expect(box.isHyperHeld == false)
    }

    @Test
    func registeredShortcutSwallowsEventAndDeliversKeyPress() async {
        let keyPress = KeyPress(keyCode: CGKeyCode(kVK_ANSI_A), modifiers: [.command])
        let event = makeKeyEvent(keyPress.keyCode, modifiers: keyPress.modifiers, keyDown: true)
        let box = EventTapBox()
        box.registeredShortcuts = [keyPress]

        let delivered: KeyPress = await withCheckedContinuation { (continuation: CheckedContinuation<KeyPress, Never>) in
            box.onKeyPress = { deliveredKeyPress in
                continuation.resume(returning: deliveredKeyPress)
            }

            let result = handleEventTapEvent(type: .keyDown, event: event, box: box)
            #expect(result == nil)
        }

        #expect(delivered == keyPress)
    }

    private func makeKeyEvent(
        _ keyCode: CGKeyCode,
        modifiers: NSEvent.ModifierFlags,
        keyDown: Bool
    ) -> CGEvent {
        let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: keyCode,
            keyDown: keyDown
        )!
        event.flags = CGEventFlags(rawValue: UInt64(modifiers.rawValue))
        return event
    }
}

private final class SendableCounter: @unchecked Sendable {
    var value = 0
}

final class LockedValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T

    init(_ value: T) {
        storage = value
    }

    var value: T {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
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
        let keyPress = KeyPress(
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
        let keyPress = KeyPress(
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
        let keyPress = KeyPress(
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
        let keyPress = KeyPress(
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
        let keyPress = KeyPress(
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
        let threeModifiers = KeyPress(
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
        let keyPress = KeyPress(
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
        let keyPress = KeyPress(
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

    @Test
    func buildIndexExcludesDisabledShortcuts() {
        let enabled = AppShortcut(appName: "A", bundleIdentifier: "com.a", keyEquivalent: "a", modifierFlags: ["command"], isEnabled: true)
        let disabled = AppShortcut(appName: "B", bundleIdentifier: "com.b", keyEquivalent: "b", modifierFlags: ["option"], isEnabled: false)
        let index = matcher.buildIndex(for: [enabled, disabled])
        #expect(index.count == 1)
        #expect(index.values.first?.bundleIdentifier == "com.a")
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

// MARK: - PersistenceService

@Suite("PersistenceService")
struct PersistenceServiceTests {
    @Test
    func roundTripEncodesAndDecodesShortcuts() {
        let shortcuts = [
            AppShortcut(appName: "Safari", bundleIdentifier: "com.apple.Safari", keyEquivalent: "s", modifierFlags: ["command", "option"]),
            AppShortcut(appName: "Terminal", bundleIdentifier: "com.apple.Terminal", keyEquivalent: "t", modifierFlags: ["command", "control", "shift"]),
        ]

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try! encoder.encode(shortcuts)
        let decoded = try! JSONDecoder().decode([AppShortcut].self, from: data)

        #expect(decoded.count == 2)
        #expect(decoded[0].bundleIdentifier == "com.apple.Safari")
        #expect(decoded[0].keyEquivalent == "s")
        #expect(decoded[0].modifierFlags == ["command", "option"])
        #expect(decoded[1].bundleIdentifier == "com.apple.Terminal")
        #expect(decoded[1].appName == "Terminal")
    }

    @Test
    func decodesEmptyArrayFromEmptyJSON() {
        let data = "[]".data(using: .utf8)!
        let decoded = try! JSONDecoder().decode([AppShortcut].self, from: data)
        #expect(decoded.isEmpty)
    }

    @Test
    func preservesUUIDThroughRoundTrip() {
        let original = AppShortcut(appName: "Test", bundleIdentifier: "com.test", keyEquivalent: "a", modifierFlags: ["command"])
        let data = try! JSONEncoder().encode([original])
        let decoded = try! JSONDecoder().decode([AppShortcut].self, from: data)
        #expect(decoded.first?.id == original.id)
    }

    @Test
    func hyperShortcutRoundTrips() {
        let shortcut = AppShortcut(
            appName: "Hyper", bundleIdentifier: "com.hyper",
            keyEquivalent: "h", modifierFlags: ["command", "option", "control", "shift"]
        )
        let data = try! JSONEncoder().encode([shortcut])
        let decoded = try! JSONDecoder().decode([AppShortcut].self, from: data)
        #expect(decoded.first?.modifierFlags == ["command", "option", "control", "shift"])
        #expect(decoded.first?.isHyper == true)
    }
}

// MARK: - ShortcutValidator with KeyMatcher unification

@Suite("ShortcutValidator alias handling")
struct ShortcutValidatorAliasTests {
    let validator = ShortcutValidator()

    @Test
    func enterAndReturnAreConsideredEquivalent() {
        let existing = AppShortcut(appName: "A", bundleIdentifier: "com.a", keyEquivalent: "return", modifierFlags: ["command"])
        let candidate = AppShortcut(appName: "B", bundleIdentifier: "com.b", keyEquivalent: "enter", modifierFlags: ["command"])
        // With unified KeyMatcher-based validation, "enter" and "return" map to the same key code
        #expect(validator.conflict(for: candidate, in: [existing]) != nil)
    }

    @Test
    func escAndEscapeAreConsideredEquivalent() {
        let existing = AppShortcut(appName: "A", bundleIdentifier: "com.a", keyEquivalent: "escape", modifierFlags: ["command"])
        let candidate = AppShortcut(appName: "B", bundleIdentifier: "com.b", keyEquivalent: "esc", modifierFlags: ["command"])
        #expect(validator.conflict(for: candidate, in: [existing]) != nil)
    }
}

// MARK: - AppShortcut isEnabled

@Suite("AppShortcut isEnabled")
struct AppShortcutIsEnabledTests {
    @Test
    func defaultsToEnabled() {
        let shortcut = AppShortcut(
            appName: "Test", bundleIdentifier: "com.test",
            keyEquivalent: "a", modifierFlags: ["command"]
        )
        #expect(shortcut.isEnabled == true)
    }

    @Test
    func canBeCreatedDisabled() {
        let shortcut = AppShortcut(
            appName: "Test", bundleIdentifier: "com.test",
            keyEquivalent: "a", modifierFlags: ["command"],
            isEnabled: false
        )
        #expect(shortcut.isEnabled == false)
    }

    @Test
    func decodesLegacyJSONWithoutIsEnabled() throws {
        let json = """
        {
            "id": "12345678-1234-1234-1234-123456789012",
            "appName": "Safari",
            "bundleIdentifier": "com.apple.Safari",
            "keyEquivalent": "s",
            "modifierFlags": ["command"]
        }
        """.data(using: .utf8)!
        let shortcut = try JSONDecoder().decode(AppShortcut.self, from: json)
        #expect(shortcut.isEnabled == true)
        #expect(shortcut.appName == "Safari")
    }

    @Test
    func roundTripsWithIsEnabled() throws {
        let original = AppShortcut(
            appName: "Test", bundleIdentifier: "com.test",
            keyEquivalent: "x", modifierFlags: ["option"],
            isEnabled: false
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppShortcut.self, from: data)
        #expect(decoded.isEnabled == false)
        #expect(decoded.id == original.id)
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
