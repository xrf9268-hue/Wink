import Foundation
import Testing
@testable import Wink

@Test @MainActor
func savingShortcutChangesInvokesConfigurationChangeHandler() {
    let shortcutStore = ShortcutStore()
    let shortcut = AppShortcut(
        appName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        keyEquivalent: "s",
        modifierFlags: ["command", "option", "control", "shift"]
    )
    shortcutStore.replaceAll(with: [shortcut])

    let manager = ShortcutManager(
        shortcutStore: shortcutStore,
        persistenceService: TestPersistenceHarness().makePersistenceService(),
        appSwitcher: FakeAppSwitcher(),
        captureCoordinator: ShortcutCaptureCoordinator(
            standardProvider: FakeCaptureProvider(),
            hyperProvider: FakeHyperCaptureProvider()
        ),
        permissionService: FakePermissionService(ax: true, input: false),
        diagnosticClient: .live
    )
    var callbackCount = 0
    let editor = ShortcutEditorState(
        shortcutStore: shortcutStore,
        shortcutManager: manager,
        onShortcutConfigurationChange: {
            callbackCount += 1
        }
    )

    editor.toggleShortcutEnabled(id: shortcut.id)
    editor.setAllEnabled(true)

    #expect(callbackCount == 2)
}

@Test @MainActor
func movingShortcutPersistsOrderAndInvokesConfigurationChangeHandler() throws {
    let shortcutStore = ShortcutStore()
    let safari = AppShortcut(
        appName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        keyEquivalent: "s",
        modifierFlags: ["command", "shift"]
    )
    let terminal = AppShortcut(
        appName: "Terminal",
        bundleIdentifier: "com.apple.Terminal",
        keyEquivalent: "t",
        modifierFlags: ["command", "shift"]
    )
    let notes = AppShortcut(
        appName: "Notes",
        bundleIdentifier: "com.apple.Notes",
        keyEquivalent: "n",
        modifierFlags: ["command", "shift"]
    )
    shortcutStore.replaceAll(with: [safari, terminal, notes])

    let persistenceHarness = TestPersistenceHarness()
    let manager = ShortcutManager(
        shortcutStore: shortcutStore,
        persistenceService: persistenceHarness.makePersistenceService(),
        appSwitcher: FakeAppSwitcher(),
        captureCoordinator: ShortcutCaptureCoordinator(
            standardProvider: FakeCaptureProvider(),
            hyperProvider: FakeHyperCaptureProvider()
        ),
        permissionService: FakePermissionService(ax: true, input: false),
        diagnosticClient: .live
    )
    var callbackCount = 0
    let editor = ShortcutEditorState(
        shortcutStore: shortcutStore,
        shortcutManager: manager,
        onShortcutConfigurationChange: {
            callbackCount += 1
        }
    )

    editor.moveShortcut(from: IndexSet(integer: 2), to: 0)

    #expect(editor.shortcuts.map(\.id) == [notes.id, safari.id, terminal.id])
    #expect(callbackCount == 1)

    let persisted = try persistenceHarness.makePersistenceService().load()
    #expect(persisted.map(\.id) == [notes.id, safari.id, terminal.id])
}

@Test @MainActor
func movingShortcutTowardEndAdjustsDestinationAfterRemoval() throws {
    let shortcutStore = ShortcutStore()
    let safari = AppShortcut(
        appName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        keyEquivalent: "s",
        modifierFlags: ["command", "shift"]
    )
    let terminal = AppShortcut(
        appName: "Terminal",
        bundleIdentifier: "com.apple.Terminal",
        keyEquivalent: "t",
        modifierFlags: ["command", "shift"]
    )
    let notes = AppShortcut(
        appName: "Notes",
        bundleIdentifier: "com.apple.Notes",
        keyEquivalent: "n",
        modifierFlags: ["command", "shift"]
    )
    shortcutStore.replaceAll(with: [safari, terminal, notes])

    let persistenceHarness = TestPersistenceHarness()
    let manager = ShortcutManager(
        shortcutStore: shortcutStore,
        persistenceService: persistenceHarness.makePersistenceService(),
        appSwitcher: FakeAppSwitcher(),
        captureCoordinator: ShortcutCaptureCoordinator(
            standardProvider: FakeCaptureProvider(),
            hyperProvider: FakeHyperCaptureProvider()
        ),
        permissionService: FakePermissionService(ax: true, input: false),
        diagnosticClient: .live
    )
    let editor = ShortcutEditorState(
        shortcutStore: shortcutStore,
        shortcutManager: manager
    )

    editor.moveShortcut(from: IndexSet(integer: 0), to: 3)

    #expect(editor.shortcuts.map(\.id) == [terminal.id, notes.id, safari.id])

    let persisted = try persistenceHarness.makePersistenceService().load()
    #expect(persisted.map(\.id) == [terminal.id, notes.id, safari.id])
}

@Test @MainActor
func beginImportBuildsPreviewWithoutPersistingChanges() throws {
    let context = makeEditorContext()
    defer { context.harness.cleanup() }

    let recipeData = try WinkRecipeCodec().encode(
        WinkRecipe(shortcuts: [
            WinkRecipeShortcut(
                appName: "Safari",
                bundleIdentifier: "com.apple.Safari",
                keyEquivalent: "s",
                modifierFlags: ["command"],
                isEnabled: true
            )
        ])
    )

    try context.editor.beginImport(
        from: recipeData,
        installedApps: [
            AppEntry(
                id: "com.apple.Safari",
                name: "Safari",
                url: URL(fileURLWithPath: "/Applications/Safari.app")
            )
        ]
    )

    let persisted = try context.harness.makePersistenceService().load()

    #expect(context.editor.pendingRecipeImport?.entries.count == 1)
    #expect(persisted.isEmpty)
    #expect(context.callbackCount.value == 0)
}

@Test @MainActor
func applyPendingImportWithReplaceExistingPersistsUpdatedShortcuts() throws {
    let context = makeEditorContext(existingShortcuts: [
        AppShortcut(
            appName: "Terminal",
            bundleIdentifier: "com.apple.Terminal",
            keyEquivalent: "s",
            modifierFlags: ["command"]
        )
    ])
    defer { context.harness.cleanup() }

    let recipeData = try WinkRecipeCodec().encode(
        WinkRecipe(shortcuts: [
            WinkRecipeShortcut(
                appName: "Safari",
                bundleIdentifier: "com.apple.Safari",
                keyEquivalent: "s",
                modifierFlags: ["command"],
                isEnabled: true
            )
        ])
    )

    try context.editor.beginImport(
        from: recipeData,
        installedApps: [
            AppEntry(
                id: "com.apple.Safari",
                name: "Safari",
                url: URL(fileURLWithPath: "/Applications/Safari.app")
            )
        ]
    )

    context.editor.applyPendingImport(strategy: .replaceExisting)

    let saved = try context.harness.makePersistenceService().load()
    #expect(saved.count == 1)
    #expect(saved[0].bundleIdentifier == "com.apple.Safari")
    #expect(context.editor.pendingRecipeImport == nil)
    #expect(context.callbackCount.value == 1)
}

@Test @MainActor
func applyPendingImportReportsActualImportedCountWhenRecipeContainsConflicts() throws {
    let context = makeEditorContext()
    defer { context.harness.cleanup() }

    let recipeData = try WinkRecipeCodec().encode(
        WinkRecipe(shortcuts: [
            WinkRecipeShortcut(
                appName: "Safari",
                bundleIdentifier: "com.apple.Safari",
                keyEquivalent: "s",
                modifierFlags: ["command"],
                isEnabled: true
            ),
            WinkRecipeShortcut(
                appName: "Terminal",
                bundleIdentifier: "com.apple.Terminal",
                keyEquivalent: "s",
                modifierFlags: ["command"],
                isEnabled: true
            ),
        ])
    )

    try context.editor.beginImport(
        from: recipeData,
        installedApps: [
            AppEntry(
                id: "com.apple.Safari",
                name: "Safari",
                url: URL(fileURLWithPath: "/Applications/Safari.app")
            ),
            AppEntry(
                id: "com.apple.Terminal",
                name: "Terminal",
                url: URL(fileURLWithPath: "/Applications/Utilities/Terminal.app")
            ),
        ]
    )

    context.editor.applyPendingImport(strategy: .replaceExisting)

    #expect(context.editor.shortcuts.count == 1)
    #expect(context.editor.recipeFeedback == .success("Imported 1 shortcuts"))
}

@Test @MainActor
func beginImportUsesBundleLocatorWhenScanCatalogMissesInstalledApp() throws {
    let context = makeEditorContext(
        appBundleLocator: TestAppBundleLocator(entries: [
            "com.apple.Safari": URL(fileURLWithPath: "/Applications/Safari.app")
        ]).locator
    )
    defer { context.harness.cleanup() }

    let recipeData = try WinkRecipeCodec().encode(
        WinkRecipe(shortcuts: [
            WinkRecipeShortcut(
                appName: "Safari",
                bundleIdentifier: "com.apple.Safari",
                keyEquivalent: "s",
                modifierFlags: ["command"],
                isEnabled: true
            )
        ])
    )

    try context.editor.beginImport(from: recipeData, installedApps: [])

    let resolution = try #require(context.editor.pendingRecipeImport?.entries.first?.imported.resolution)
    #expect(resolution == .matchedByBundleIdentifier)
}

@Test @MainActor
func importRecipesForcesFreshAppScanBeforePlanning() async throws {
    let recorder = ImportScanRecorder(now: Date(timeIntervalSinceReferenceDate: 500))
    let recipeData = try WinkRecipeCodec().encode(
        WinkRecipe(shortcuts: [
            WinkRecipeShortcut(
                appName: "Safari",
                bundleIdentifier: "com.example.missing",
                keyEquivalent: "s",
                modifierFlags: ["command"],
                isEnabled: true
            )
        ])
    )
    let transferClient = ShortcutEditorState.RecipeTransferClient(
        importData: { recipeData },
        exportData: { _, _ in nil }
    )
    let context = makeEditorContext(
        recipeTransferClient: transferClient,
        appBundleLocator: TestAppBundleLocator(entries: [:]).locator
    )
    defer { context.harness.cleanup() }

    let appListProvider = AppListProvider(client: .init(
        now: { recorder.now },
        scanInstalledApps: {
            recorder.scanCallCount += 1
            if recorder.scanCallCount == 1 {
                return []
            }
            return [
                AppEntry(
                    id: "com.apple.Safari",
                    name: "Safari",
                    url: URL(fileURLWithPath: "/Applications/Safari.app")
                )
            ]
        },
        runningApplications: { [] },
        loadRecents: { [] },
        saveRecents: { _ in },
        mainBundleIdentifier: { nil }
    ))

    appListProvider.refreshIfNeeded()
    await appListProvider.waitForRefreshForTesting()
    recorder.now = recorder.now.addingTimeInterval(10)

    await context.editor.importRecipes(using: appListProvider)

    #expect(recorder.scanCallCount == 2)
    let resolution = try #require(context.editor.pendingRecipeImport?.entries.first?.imported.resolution)
    #expect(resolution == .matchedByAppName)
}

@Test @MainActor
func exportRecipeDataUsesShareableSchema() throws {
    let context = makeEditorContext(existingShortcuts: [
        AppShortcut(
            appName: "IINA",
            bundleIdentifier: "com.colliderli.iina",
            keyEquivalent: "i",
            modifierFlags: ["command", "option"],
            isEnabled: false
        )
    ])
    defer { context.harness.cleanup() }

    let data = try context.editor.exportRecipeData()
    let decoded = try WinkRecipeCodec().decode(data)

    #expect(decoded.schemaVersion == WinkRecipe.currentSchemaVersion)
    #expect(decoded.shortcuts == [
        WinkRecipeShortcut(
            appName: "IINA",
            bundleIdentifier: "com.colliderli.iina",
            keyEquivalent: "i",
            modifierFlags: ["command", "option"],
            isEnabled: false
        )
    ])
}

private struct FakePermissionService: PermissionServicing {
    let ax: Bool
    let input: Bool

    func isTrusted() -> Bool {
        ax && input
    }

    func isAccessibilityTrusted() -> Bool {
        ax
    }

    func isInputMonitoringTrusted() -> Bool {
        input
    }

    @discardableResult
    func requestIfNeeded(prompt: Bool, inputMonitoringRequired: Bool) -> Bool {
        ax && (!inputMonitoringRequired || input)
    }
}

@MainActor
private final class FakeCaptureProvider: ShortcutCaptureProvider {
    var isRunning = false

    var registrationState: ShortcutCaptureRegistrationState {
        ShortcutCaptureRegistrationState(
            desiredShortcutCount: isRunning ? 1 : 0,
            registeredShortcutCount: isRunning ? 1 : 0,
            failures: []
        )
    }

    func start(onKeyPress: @escaping @MainActor @Sendable (KeyPress) -> Void) {
        isRunning = true
    }

    func stop() {
        isRunning = false
    }

    func updateRegisteredShortcuts(_ keyPresses: Set<KeyPress>) {}
}

@MainActor
private final class FakeHyperCaptureProvider: HyperShortcutCaptureProvider {
    var isRunning = false

    var registrationState: ShortcutCaptureRegistrationState {
        ShortcutCaptureRegistrationState(
            desiredShortcutCount: isRunning ? 1 : 0,
            registeredShortcutCount: isRunning ? 1 : 0,
            failures: []
        )
    }

    func start(onKeyPress: @escaping @MainActor @Sendable (KeyPress) -> Void) {
        isRunning = true
    }

    func stop() {
        isRunning = false
    }

    func updateRegisteredShortcuts(_ keyPresses: Set<KeyPress>) {}

    func setHyperKeyEnabled(_ enabled: Bool) {}
}

@MainActor
private struct FakeAppSwitcher: AppSwitching {
    @discardableResult
    func toggleApplication(for shortcut: AppShortcut) -> Bool {
        true
    }
}

private final class CallbackCounter: @unchecked Sendable {
    var value = 0
}

private final class ImportScanRecorder: @unchecked Sendable {
    var now: Date
    var scanCallCount = 0

    init(now: Date) {
        self.now = now
    }
}

@MainActor
private func makeEditorContext(
    existingShortcuts: [AppShortcut] = [],
    recipeTransferClient: ShortcutEditorState.RecipeTransferClient = .init(
        importData: { nil },
        exportData: { _, _ in nil }
    ),
    appBundleLocator: AppBundleLocator = TestAppBundleLocator(entries: [:]).locator
) -> (
    editor: ShortcutEditorState,
    manager: ShortcutManager,
    shortcutStore: ShortcutStore,
    harness: TestPersistenceHarness,
    callbackCount: CallbackCounter
) {
    let shortcutStore = ShortcutStore()
    shortcutStore.replaceAll(with: existingShortcuts)

    let harness = TestPersistenceHarness()
    let manager = ShortcutManager(
        shortcutStore: shortcutStore,
        persistenceService: harness.makePersistenceService(),
        appSwitcher: FakeAppSwitcher(),
        captureCoordinator: ShortcutCaptureCoordinator(
            standardProvider: FakeCaptureProvider(),
            hyperProvider: FakeHyperCaptureProvider()
        ),
        permissionService: FakePermissionService(ax: true, input: false),
        diagnosticClient: .live
    )

    if !existingShortcuts.isEmpty {
        manager.save(shortcuts: existingShortcuts)
    }

    let callbackCount = CallbackCounter()
    let editor = ShortcutEditorState(
        shortcutStore: shortcutStore,
        shortcutManager: manager,
        recipeTransferClient: recipeTransferClient,
        appBundleLocator: appBundleLocator,
        onShortcutConfigurationChange: {
            callbackCount.value += 1
        }
    )

    return (editor, manager, shortcutStore, harness, callbackCount)
}
