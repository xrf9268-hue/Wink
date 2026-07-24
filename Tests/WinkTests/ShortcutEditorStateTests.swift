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

@MainActor
private func makeFailingSaveEditorContext(
    existingShortcuts: [AppShortcut]
) -> (editor: ShortcutEditorState, shortcutStore: ShortcutStore, callbackCount: CallbackCounter) {
    let shortcutStore = ShortcutStore()
    shortcutStore.replaceAll(with: existingShortcuts)

    let manager = ShortcutManager(
        shortcutStore: shortcutStore,
        persistenceService: PersistenceService(storageURLProvider: { nil }),
        appSwitcher: FakeAppSwitcher(),
        captureCoordinator: ShortcutCaptureCoordinator(
            standardProvider: FakeCaptureProvider(),
            hyperProvider: FakeHyperCaptureProvider()
        ),
        permissionService: FakePermissionService(ax: true, input: false),
        diagnosticClient: .init(log: { _ in })
    )
    let callbackCount = CallbackCounter()
    let editor = ShortcutEditorState(
        shortcutStore: shortcutStore,
        shortcutManager: manager,
        onShortcutConfigurationChange: {
            callbackCount.value += 1
        }
    )
    return (editor, shortcutStore, callbackCount)
}

@Test @MainActor
func failedSaveRevertsEditorShortcutsAndSurfacesError() {
    let safari = AppShortcut(
        appName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        keyEquivalent: "s",
        modifierFlags: ["command", "shift"]
    )
    let context = makeFailingSaveEditorContext(existingShortcuts: [safari])

    context.editor.removeShortcut(id: safari.id)

    #expect(context.editor.shortcuts == [safari])
    #expect(context.shortcutStore.shortcuts == [safari])
    #expect(context.editor.saveErrorMessage?.contains("Failed to save shortcuts") == true)
    #expect(context.callbackCount.value == 0)
}

@Test @MainActor
func failedToggleLeavesEnabledStateUnchanged() {
    let safari = AppShortcut(
        appName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        keyEquivalent: "s",
        modifierFlags: ["command", "shift"]
    )
    let context = makeFailingSaveEditorContext(existingShortcuts: [safari])

    context.editor.toggleShortcutEnabled(id: safari.id)

    #expect(context.editor.shortcuts.first?.isEnabled == true)
    #expect(context.shortcutStore.shortcuts.first?.isEnabled == true)
    #expect(context.editor.saveErrorMessage != nil)
}

/// #356 P2-5 regression: a persistence failure while committing the
/// search-palette trigger must surface on the General tab's own card
/// (`searchPaletteSaveErrorMessage`), not only the shared `saveErrorMessage`
/// that only `ShortcutsTabView` renders.
@Test @MainActor
func commitSearchPaletteShortcutSurfacesAPaletteScopedSaveError() {
    let context = makeFailingSaveEditorContext(existingShortcuts: [])

    context.editor.commitSearchPaletteShortcut(
        RecordedShortcut(keyEquivalent: "space", modifierFlags: ["command", "option"])
    )

    #expect(context.editor.searchPaletteShortcut == nil)
    #expect(context.editor.searchPaletteSaveErrorMessage != nil)
    #expect(context.editor.searchPaletteSaveErrorMessage == context.editor.saveErrorMessage)
    #expect(context.editor.recordedSearchPaletteShortcut == nil)
}

@Test @MainActor
func setSearchPaletteEnabledSurfacesAPaletteScopedSaveError() {
    let trigger = AppShortcut(
        appName: AppShortcut.searchPaletteTargetStableName,
        bundleIdentifier: AppShortcut.searchPaletteTargetSentinelBundleIdentifier,
        keyEquivalent: "space",
        modifierFlags: ["command", "option"],
        target: .searchPalette
    )
    let context = makeFailingSaveEditorContext(existingShortcuts: [trigger])

    context.editor.setSearchPaletteEnabled(false)

    #expect(context.editor.searchPaletteShortcut?.isEnabled == true)
    #expect(context.editor.searchPaletteSaveErrorMessage != nil)
}

@Test @MainActor
func removeSearchPaletteShortcutSurfacesAPaletteScopedSaveError() {
    let trigger = AppShortcut(
        appName: AppShortcut.searchPaletteTargetStableName,
        bundleIdentifier: AppShortcut.searchPaletteTargetSentinelBundleIdentifier,
        keyEquivalent: "space",
        modifierFlags: ["command", "option"],
        target: .searchPalette
    )
    let context = makeFailingSaveEditorContext(existingShortcuts: [trigger])

    context.editor.removeSearchPaletteShortcut()

    #expect(context.editor.searchPaletteShortcut != nil)
    #expect(context.editor.searchPaletteSaveErrorMessage != nil)
}

/// #356 P2-5: a successful commit clears any prior palette-scoped error.
@Test @MainActor
func commitSearchPaletteShortcutClearsAPriorPaletteScopedSaveError() {
    let context = makeEditorContext()
    defer { context.harness.cleanup() }

    context.editor.searchPaletteSaveErrorMessage = "stale error"
    context.editor.commitSearchPaletteShortcut(
        RecordedShortcut(keyEquivalent: "space", modifierFlags: ["command", "option"])
    )

    #expect(context.editor.searchPaletteSaveErrorMessage == nil)
}

@Test @MainActor
func successfulSaveClearsPreviousSaveError() {
    let context = makeEditorContext()
    defer { context.harness.cleanup() }

    context.editor.saveErrorMessage = "stale error"
    context.editor.setAllEnabled(true)

    #expect(context.editor.saveErrorMessage == nil)
}

@Test @MainActor
func editorSynchronizesWhenShortcutStoreChangesExternally() async {
    let context = makeEditorContext()
    defer { context.harness.cleanup() }

    let safari = AppShortcut(
        appName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        keyEquivalent: "s",
        modifierFlags: ["command", "shift"]
    )

    context.shortcutStore.replaceAll(with: [safari])

    await waitUntil("editor syncs loaded shortcuts from store") {
        context.editor.shortcuts.map(\.id) == [safari.id]
    }

    #expect(context.editor.shortcuts.map(\.id) == [safari.id])
    #expect(context.editor.allEnabled == true)

    var disabledSafari = safari
    disabledSafari.isEnabled = false
    context.shortcutStore.replaceAll(with: [disabledSafari])

    await waitUntil("editor syncs enabled state from store") {
        context.editor.shortcuts.first?.isEnabled == false
    }

    #expect(context.editor.shortcuts.first?.isEnabled == false)
    #expect(context.editor.allEnabled == false)
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
func reorderingShortcutToVisibleDropOffsetPersistsOrder() throws {
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
    let chrome = AppShortcut(
        appName: "Chrome",
        bundleIdentifier: "com.google.Chrome",
        keyEquivalent: "c",
        modifierFlags: ["command", "shift"]
    )
    let context = makeEditorContext(existingShortcuts: [safari, terminal, notes, chrome])
    defer { context.harness.cleanup() }

    context.editor.reorderShortcut(
        draggedID: safari.id,
        toVisibleOffset: 3,
        visibleShortcutIDs: [safari.id, terminal.id, notes.id, chrome.id]
    )

    #expect(context.editor.shortcuts.map(\.id) == [terminal.id, notes.id, safari.id, chrome.id])
    #expect(context.callbackCount.value == 1)

    let persisted = try context.harness.makePersistenceService().load()
    #expect(persisted.map(\.id) == [terminal.id, notes.id, safari.id, chrome.id])
}

@Test @MainActor
func reorderingMiddleShortcutToMiddleVisibleDropOffsetPersistsOrder() throws {
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
    let chrome = AppShortcut(
        appName: "Chrome",
        bundleIdentifier: "com.google.Chrome",
        keyEquivalent: "c",
        modifierFlags: ["command", "shift"]
    )
    let context = makeEditorContext(existingShortcuts: [safari, terminal, notes, chrome])
    defer { context.harness.cleanup() }

    context.editor.reorderShortcut(
        draggedID: notes.id,
        toVisibleOffset: 1,
        visibleShortcutIDs: [safari.id, terminal.id, notes.id, chrome.id]
    )

    #expect(context.editor.shortcuts.map(\.id) == [safari.id, notes.id, terminal.id, chrome.id])
    #expect(context.callbackCount.value == 1)

    let persisted = try context.harness.makePersistenceService().load()
    #expect(persisted.map(\.id) == [safari.id, notes.id, terminal.id, chrome.id])
}

@Test
func reorderPlannerMapsDownwardDragToVisibleInsertionOffset() {
    let ids = (0..<4).map { _ in UUID() }
    let rowFrames = rowFrames(for: ids)

    let offset = ShortcutReorderPlanner.visibleDropOffset(
        for: ids[0],
        translationY: 110,
        visibleShortcutIDs: ids,
        rowFrames: rowFrames
    )

    #expect(offset == 3)
}

@Test
func reorderPlannerMapsUpwardDragToVisibleInsertionOffset() {
    let ids = (0..<4).map { _ in UUID() }
    let rowFrames = rowFrames(for: ids)

    let offset = ShortcutReorderPlanner.visibleDropOffset(
        for: ids[3],
        translationY: -110,
        visibleShortcutIDs: ids,
        rowFrames: rowFrames
    )

    #expect(offset == 1)
}

@Test
func reorderPlannerMapsDropOffsetAcrossDividerGap() {
    let ids = (0..<4).map { _ in UUID() }
    let rowFrames = rowFrames(for: ids, dividerGap: 1)
    let translationY = rowFrames[ids[0], default: .zero].maxY + 0.5 - rowFrames[ids[2], default: .zero].midY

    let offset = ShortcutReorderPlanner.visibleDropOffset(
        for: ids[2],
        translationY: translationY,
        visibleShortcutIDs: ids,
        rowFrames: rowFrames
    )

    #expect(offset == 1)
}

@Test
func reorderPlannerMapsDropOffsetAcrossVariableRowHeights() {
    let ids = (0..<4).map { _ in UUID() }
    let rowFrames = rowFrames(for: ids, rowHeights: [50, 68, 50, 50], dividerGap: 1)
    let translationY = rowFrames[ids[1], default: .zero].maxY + 0.5 - rowFrames[ids[3], default: .zero].midY

    let offset = ShortcutReorderPlanner.visibleDropOffset(
        for: ids[3],
        translationY: translationY,
        visibleShortcutIDs: ids,
        rowFrames: rowFrames
    )

    #expect(offset == 2)
}

@Test
func reorderPlannerUsesDragStartSourceFrameWhenCurrentSourceFrameFollowsOffset() {
    let ids = (0..<4).map { _ in UUID() }
    let dragStartFrames = rowFrames(for: ids, dividerGap: 1)
    let translationY = dragStartFrames[ids[0], default: .zero].maxY + 0.5
        - dragStartFrames[ids[2], default: .zero].midY
    var currentFrames = dragStartFrames
    currentFrames[ids[2]] = dragStartFrames[ids[2], default: .zero].offsetBy(dx: 0, dy: translationY)

    let offset = ShortcutReorderPlanner.visibleDropOffset(
        for: ids[2],
        translationY: translationY,
        visibleShortcutIDs: ids,
        rowFrames: currentFrames,
        sourceFrame: dragStartFrames[ids[2]]
    )

    #expect(offset == 1)
}

@Test
func reorderPlannerUsesVisibleIndexesWhenLazyStackOnlyReportsMountedRows() {
    let ids = (0..<25).map { _ in UUID() }
    let allFrames = rowFrames(for: ids, dividerGap: 1)
    let mountedIDs = ids[17...24]
    let mountedFrames = Dictionary(uniqueKeysWithValues: mountedIDs.map { id in
        (id, allFrames[id, default: .zero])
    })
    let translationY = allFrames[ids[24], default: .zero].maxY + 0.5
        - allFrames[ids[23], default: .zero].midY

    let offset = ShortcutReorderPlanner.visibleDropOffset(
        for: ids[23],
        translationY: translationY,
        visibleShortcutIDs: ids,
        rowFrames: mountedFrames,
        sourceFrame: allFrames[ids[23]]
    )

    #expect(offset == ids.count)
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

private func rowFrames(for ids: [UUID]) -> [UUID: CGRect] {
    rowFrames(for: ids, rowHeights: Array(repeating: 50, count: ids.count))
}

private func rowFrames(
    for ids: [UUID],
    rowHeights: [CGFloat]? = nil,
    dividerGap: CGFloat = 0
) -> [UUID: CGRect] {
    let heights = rowHeights ?? Array(repeating: 50, count: ids.count)
    var y: CGFloat = 0
    var frames: [(UUID, CGRect)] = []

    for (index, id) in ids.enumerated() {
        let rowHeight = heights[index]
        frames.append((
            id,
            CGRect(
                x: 0,
                y: y,
                width: 400,
                height: rowHeight
            )
        ))
        y += rowHeight
        if index < ids.count - 1 {
            y += dividerGap
        }
    }

    return Dictionary(uniqueKeysWithValues: frames)
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

// MARK: - Search-palette trigger recorder (#356)

@Test @MainActor
func commitSearchPaletteShortcutPersistsAnEnabledTrigger() throws {
    let context = makeEditorContext()
    defer { context.harness.cleanup() }

    context.editor.commitSearchPaletteShortcut(
        RecordedShortcut(keyEquivalent: "space", modifierFlags: ["command", "option"])
    )

    let persisted = try #require(context.editor.searchPaletteShortcut)
    #expect(persisted.isSearchPaletteTarget)
    #expect(persisted.isEnabled)
    #expect(persisted.keyEquivalent == "space")
    #expect(persisted.modifierFlags == ["command", "option"])
    #expect(context.editor.searchPaletteConflictMessage == nil)
    #expect(context.editor.recordedSearchPaletteShortcut == nil)
    #expect(context.callbackCount.value == 1)
    #expect(context.shortcutStore.shortcuts.count == 1)
}

@Test @MainActor
func commitSearchPaletteShortcutReplacesThePriorBindingInPlace() throws {
    let context = makeEditorContext()
    defer { context.harness.cleanup() }

    context.editor.commitSearchPaletteShortcut(
        RecordedShortcut(keyEquivalent: "space", modifierFlags: ["command", "option"])
    )
    let firstID = try #require(context.editor.searchPaletteShortcut?.id)

    context.editor.commitSearchPaletteShortcut(
        RecordedShortcut(keyEquivalent: "j", modifierFlags: ["command", "option"])
    )

    // Re-recording replaces the one binding rather than accumulating a
    // second search-palette row.
    #expect(context.shortcutStore.shortcuts.count == 1)
    #expect(context.editor.searchPaletteShortcut?.id == firstID)
    #expect(context.editor.searchPaletteShortcut?.keyEquivalent == "j")
}

@Test @MainActor
func commitSearchPaletteShortcutRejectsAConflictWithAnExistingAppShortcut() throws {
    let safari = AppShortcut(
        appName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        keyEquivalent: "s",
        modifierFlags: ["command", "shift"]
    )
    let context = makeEditorContext(existingShortcuts: [safari])
    defer { context.harness.cleanup() }

    context.editor.commitSearchPaletteShortcut(
        RecordedShortcut(keyEquivalent: "s", modifierFlags: ["command", "shift"])
    )

    #expect(context.editor.searchPaletteShortcut == nil)
    #expect(context.editor.recordedSearchPaletteShortcut == nil)
    #expect(context.editor.searchPaletteConflictMessage?.contains("Safari") == true)
    #expect(context.shortcutStore.shortcuts == [safari])
}

@Test @MainActor
func addingAnAppShortcutRejectsAConflictWithAnExistingSearchPaletteTrigger() throws {
    let context = makeEditorContext()
    defer { context.harness.cleanup() }

    context.editor.commitSearchPaletteShortcut(
        RecordedShortcut(keyEquivalent: "space", modifierFlags: ["command", "option"])
    )

    context.editor.selectedAppName = "Safari"
    context.editor.selectedBundleIdentifier = "com.apple.Safari"
    context.editor.recordedShortcut = RecordedShortcut(keyEquivalent: "space", modifierFlags: ["command", "option"])
    context.editor.addShortcut()

    // The conflict message resolves through `displayAppName`, so the
    // colliding search-palette trigger reads as "Search Palette", not its
    // sentinel bundle identifier.
    #expect(context.editor.conflictMessage?.contains("Search Palette") == true)
    #expect(context.shortcutStore.shortcuts.count == 1)
    #expect(context.shortcutStore.shortcuts.first?.isSearchPaletteTarget == true)
}

@Test @MainActor
func setSearchPaletteEnabledTogglesWithoutRemovingTheBinding() throws {
    let context = makeEditorContext()
    defer { context.harness.cleanup() }

    context.editor.commitSearchPaletteShortcut(
        RecordedShortcut(keyEquivalent: "space", modifierFlags: ["command", "option"])
    )
    let callbackCountAfterCommit = context.callbackCount.value

    context.editor.setSearchPaletteEnabled(false)
    #expect(context.editor.searchPaletteShortcut?.isEnabled == false)
    #expect(context.callbackCount.value == callbackCountAfterCommit + 1)

    // Same value again is a no-op, matching setFrontmostBehaviorOverride's
    // established no-op-on-unchanged-value contract.
    context.editor.setSearchPaletteEnabled(false)
    #expect(context.callbackCount.value == callbackCountAfterCommit + 1)

    context.editor.setSearchPaletteEnabled(true)
    #expect(context.editor.searchPaletteShortcut?.isEnabled == true)
    #expect(context.callbackCount.value == callbackCountAfterCommit + 2)
}

@Test @MainActor
func removeSearchPaletteShortcutClearsTheBinding() throws {
    let context = makeEditorContext()
    defer { context.harness.cleanup() }

    context.editor.commitSearchPaletteShortcut(
        RecordedShortcut(keyEquivalent: "space", modifierFlags: ["command", "option"])
    )
    #expect(context.editor.searchPaletteShortcut != nil)

    context.editor.removeSearchPaletteShortcut()

    #expect(context.editor.searchPaletteShortcut == nil)
    #expect(context.shortcutStore.shortcuts.isEmpty)
}

@Test @MainActor
func removeSearchPaletteShortcutWithNoBindingIsANoOp() throws {
    let context = makeEditorContext()
    defer { context.harness.cleanup() }

    context.editor.removeSearchPaletteShortcut()

    #expect(context.callbackCount.value == 0)
    #expect(context.shortcutStore.shortcuts.isEmpty)
}

@Test @MainActor
func exportRecipeDataExcludesTheSearchPaletteTrigger() throws {
    let safari = AppShortcut(
        appName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        keyEquivalent: "s",
        modifierFlags: ["command", "shift"]
    )
    let context = makeEditorContext(existingShortcuts: [safari])
    defer { context.harness.cleanup() }

    context.editor.commitSearchPaletteShortcut(
        RecordedShortcut(keyEquivalent: "space", modifierFlags: ["command", "option"])
    )
    // Both a real binding and the trigger now live in the store...
    #expect(context.shortcutStore.shortcuts.count == 2)

    // ...but only the real binding travels in an exported recipe — the
    // trigger is a local device preference, not a portable app binding.
    let data = try context.editor.exportRecipeData()
    let decoded = try WinkRecipeCodec().decode(data)
    #expect(decoded.shortcuts.map(\.bundleIdentifier) == ["com.apple.Safari"])
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
    func toggleApplication(for shortcut: AppShortcut, bypassCooldown: Bool) -> Bool {
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
private func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(2),
    pollInterval: Duration = .milliseconds(20),
    condition: @escaping @MainActor () -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        if clock.now >= deadline {
            Issue.record("Timed out waiting for: \(description)")
            return
        }
        try? await Task.sleep(for: pollInterval)
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
        try! manager.save(shortcuts: existingShortcuts)
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

@Test @MainActor
func staleUsageRefreshCannotOverwriteNewerPublishedUsageData() async {
    let shortcutStore = ShortcutStore()
    let manager = ShortcutManager(
        shortcutStore: shortcutStore,
        persistenceService: TestPersistenceHarness().makePersistenceService(),
        appSwitcher: FakeAppSwitcher(),
        captureCoordinator: ShortcutCaptureCoordinator(
            standardProvider: FakeCaptureProvider(),
            hyperProvider: FakeHyperCaptureProvider()
        ),
        permissionService: FakePermissionService(ax: true, input: false),
        diagnosticClient: .init(log: { _ in })
    )
    let tracker = GatedUsageTracker()
    let editor = ShortcutEditorState(
        shortcutStore: shortcutStore,
        shortcutManager: manager,
        usageTracker: tracker
    )
    let shortcutID = UUID()

    // Drain the init-scheduled refresh so the scenario owns the gate.
    await waitForPendingUsageCounts(on: tracker, count: 1)
    await tracker.releaseFirstUsageCounts(returning: [:])
    await waitForPendingUsageCounts(on: tracker, count: 0)

    let staleLastUsed = [shortcutID: Date(timeIntervalSinceReferenceDate: 100)]
    let freshLastUsed = [shortcutID: Date(timeIntervalSinceReferenceDate: 900)]

    await tracker.setLastUsedValue(staleLastUsed)
    let staleRefresh = Task { await editor.refreshUsageCounts() }
    await waitForPendingUsageCounts(on: tracker, count: 1)

    await tracker.setLastUsedValue(freshLastUsed)
    let freshRefresh = Task { await editor.refreshUsageCounts() }
    await waitForPendingUsageCounts(on: tracker, count: 2)

    // The newer refresh completes first and publishes.
    await tracker.releaseLastUsageCounts(returning: [shortcutID: 9])
    await freshRefresh.value

    #expect(editor.usageCounts == [shortcutID: 9])
    #expect(editor.lastUsed == freshLastUsed)

    // The superseded refresh finishes afterwards; its stale result must be
    // discarded instead of tearing the published usage maps.
    await tracker.releaseFirstUsageCounts(returning: [shortcutID: 1])
    await staleRefresh.value

    #expect(editor.usageCounts == [shortcutID: 9])
    #expect(editor.lastUsed == freshLastUsed)
}

@MainActor
private func waitForPendingUsageCounts(on tracker: GatedUsageTracker, count: Int) async {
    for _ in 0..<5000 {
        if await tracker.pendingUsageCountsCount() == count {
            return
        }
        await Task.yield()
    }
    Issue.record("timed out waiting for \(count) pending usageCounts calls")
}

private actor GatedUsageTracker: UsageTracking {

    func appActivationTotals(days: Int, relativeTo now: Date) async -> [(bundleIdentifier: String, count: Int)] {
        []
    }
    func deleteUsage(shortcutId: UUID) {}
    private var pendingUsageCounts: [CheckedContinuation<[UUID: Int], Never>] = []
    private var lastUsedValue: [UUID: Date] = [:]

    func setLastUsedValue(_ value: [UUID: Date]) {
        lastUsedValue = value
    }

    func pendingUsageCountsCount() -> Int {
        pendingUsageCounts.count
    }

    func releaseFirstUsageCounts(returning value: [UUID: Int]) {
        guard !pendingUsageCounts.isEmpty else { return }
        pendingUsageCounts.removeFirst().resume(returning: value)
    }

    func releaseLastUsageCounts(returning value: [UUID: Int]) {
        guard !pendingUsageCounts.isEmpty else { return }
        pendingUsageCounts.removeLast().resume(returning: value)
    }

    func usageCounts(days: Int, relativeTo now: Date) async -> [UUID: Int] {
        await withCheckedContinuation { pendingUsageCounts.append($0) }
    }

    func dailyCounts(days: Int, relativeTo now: Date) async -> [String: [(date: String, count: Int)]] {
        [:]
    }

    func totalSwitches(days: Int, relativeTo now: Date) async -> Int {
        0
    }

    func hourlyCounts(days: Int, relativeTo now: Date) async -> [HourlyUsageBucket] {
        []
    }

    func previousPeriodTotal(days: Int, relativeTo now: Date) async -> Int {
        0
    }

    func streakDays(relativeTo now: Date) async -> Int {
        0
    }

    func usageTimeZone() async -> TimeZone {
        .current
    }

    func lastUsedPerShortcut() async -> [UUID: Date] {
        lastUsedValue
    }
}

// MARK: - Editor state

@Test @MainActor
func setFrontmostBehaviorOverridePersistsAndNotifiesOnce() {
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

    editor.setFrontmostBehaviorOverride(id: shortcut.id, behavior: .cycleWindows)
    #expect(shortcutStore.shortcuts.first?.frontmostBehaviorOverride == .cycleWindows)
    #expect(callbackCount == 1)

    // Same value again is a no-op: no persist, no notification.
    editor.setFrontmostBehaviorOverride(id: shortcut.id, behavior: .cycleWindows)
    #expect(callbackCount == 1)

    editor.setFrontmostBehaviorOverride(id: shortcut.id, behavior: nil)
    #expect(shortcutStore.shortcuts.first?.frontmostBehaviorOverride == nil)
    #expect(callbackCount == 2)

    // Hold action mirrors the override lifecycle: persist + notify once,
    // same-value no-op, nil clears.
    editor.setHoldAction(id: shortcut.id, holdAction: .windowPicker)
    #expect(shortcutStore.shortcuts.first?.holdAction == .windowPicker)
    #expect(callbackCount == 3)

    editor.setHoldAction(id: shortcut.id, holdAction: .windowPicker)
    #expect(callbackCount == 3)

    editor.setHoldAction(id: shortcut.id, holdAction: nil)
    #expect(shortcutStore.shortcuts.first?.holdAction == nil)
    #expect(callbackCount == 4)
}

@Test @MainActor
func manualAndExceptionPausesComposeWithManualWinning() {
    let shortcutStore = ShortcutStore()
    let manager = ShortcutManager(
        shortcutStore: shortcutStore,
        persistenceService: TestPersistenceHarness().makePersistenceService(),
        appSwitcher: FakeAppSwitcher(),
        captureCoordinator: ShortcutCaptureCoordinator(
            standardProvider: FakeCaptureProvider(),
            hyperProvider: FakeHyperCaptureProvider()
        ),
        permissionService: FakePermissionService(ax: true, input: false),
        diagnosticClient: .init(log: { _ in })
    )

    manager.setAutoPausedByException(true)
    #expect(manager.shortcutCaptureStatus().shortcutsPaused == true)

    // Manual pause engages while auto is active; lifting the exception
    // must NOT resume capture — the user's explicit pause wins.
    manager.setShortcutsPaused(true)
    manager.setAutoPausedByException(false)
    #expect(manager.shortcutCaptureStatus().shortcutsPaused == true)

    manager.setShortcutsPaused(false)
    #expect(manager.shortcutCaptureStatus().shortcutsPaused == false)

    // And the reverse: manual resume under an active exception keeps
    // capture paused until the exception lifts too.
    manager.setShortcutsPaused(true)
    manager.setAutoPausedByException(true)
    manager.setShortcutsPaused(false)
    #expect(manager.shortcutCaptureStatus().shortcutsPaused == true)
    manager.setAutoPausedByException(false)
    #expect(manager.shortcutCaptureStatus().shortcutsPaused == false)
}

@Test @MainActor
func captureStatusReflectsSecureInputProbeAndPollNotifiesOnChange() {
    let shortcutStore = ShortcutStore()
    var secureInput = false
    var statusChangeNotifications = 0
    let manager = ShortcutManager(
        shortcutStore: shortcutStore,
        persistenceService: TestPersistenceHarness().makePersistenceService(),
        appSwitcher: FakeAppSwitcher(),
        captureCoordinator: ShortcutCaptureCoordinator(
            standardProvider: FakeCaptureProvider(),
            hyperProvider: FakeHyperCaptureProvider()
        ),
        permissionService: FakePermissionService(ax: true, input: false),
        secureInputProbe: { secureInput },
        diagnosticClient: .init(log: { _ in })
    )
    manager.onCaptureStatusChange = { _ in
        statusChangeNotifications += 1
    }

    #expect(manager.shortcutCaptureStatus().secureInputActive == false)

    secureInput = true
    #expect(manager.shortcutCaptureStatus().secureInputActive == true)

    // The 3s poll notifies exactly once per transition, both directions.
    manager.checkPermissionChange()
    #expect(statusChangeNotifications == 1)
    manager.checkPermissionChange()
    #expect(statusChangeNotifications == 1)
    secureInput = false
    manager.checkPermissionChange()
    #expect(statusChangeNotifications == 2)
}

@Test @MainActor
func recordingGenerationsBumpPerLaneOnlyOnStartTransitions() {
    // #420: the generations identify recording sessions for the recorder's
    // teardown-deferred cancel guard. Only a false→true transition is a new
    // session; redundant true writes and stops must not advance them, and
    // the two lanes must stay independent (a shared counter would let a
    // palette session suppress the composer lane's still-needed cancel).
    let (editor, _, _, _, _) = makeEditorContext()

    #expect(editor.shortcutRecordingGeneration == 0)
    #expect(editor.searchPaletteRecordingGeneration == 0)

    editor.isRecordingShortcut = true
    #expect(editor.shortcutRecordingGeneration == 1)
    editor.isRecordingShortcut = true
    #expect(editor.shortcutRecordingGeneration == 1)
    editor.isRecordingShortcut = false
    #expect(editor.shortcutRecordingGeneration == 1)
    editor.isRecordingShortcut = true
    #expect(editor.shortcutRecordingGeneration == 2)

    editor.isRecordingSearchPaletteShortcut = true
    #expect(editor.searchPaletteRecordingGeneration == 1)
    #expect(editor.shortcutRecordingGeneration == 2)
}
