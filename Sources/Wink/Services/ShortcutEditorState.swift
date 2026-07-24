import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class ShortcutEditorState {
    enum RecipeFeedback: Equatable {
        case success(String)
        case error(String)

        var message: String {
            switch self {
            case let .success(message), let .error(message):
                message
            }
        }

        var isError: Bool {
            if case .error = self {
                return true
            }
            return false
        }
    }

    struct RecipeTransferClient {
        let importData: @MainActor () throws -> Data?
        let exportData: @MainActor (_ suggestedFilename: String, _ data: Data) throws -> URL?

        static let live = RecipeTransferClient(
            importData: {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = recipeContentTypes(includeLegacyImport: true)
                panel.allowsMultipleSelection = false
                panel.canChooseDirectories = false
                panel.canChooseFiles = true

                guard panel.runModal() == .OK,
                      let url = panel.url else {
                    return nil
                }

                return try Data(contentsOf: url)
            },
            exportData: { suggestedFilename, data in
                let panel = NSSavePanel()
                panel.allowedContentTypes = recipeContentTypes(includeLegacyImport: false)
                panel.canCreateDirectories = true
                panel.directoryURL = StoragePaths.appSupportDirectory()
                panel.nameFieldStringValue = suggestedFilename

                guard panel.runModal() == .OK,
                      let selectedURL = panel.url else {
                    return nil
                }

                let finalURL: URL
                if selectedURL.pathExtension.isEmpty {
                    finalURL = selectedURL.appendingPathExtension("winkrecipe")
                } else {
                    finalURL = selectedURL
                }

                try data.write(to: finalURL, options: .atomic)
                return finalURL
            }
        )
    }

    var shortcuts: [AppShortcut] = []
    var selectedAppName: String = ""
    var selectedBundleIdentifier: String = ""
    var recordedShortcut: RecordedShortcut?
    var isRecordingShortcut: Bool = false {
        didSet { syncRecordingSessionGate() }
    }
    var conflictMessage: String?
    var saveErrorMessage: String?
    /// Recording state for the #356 search-palette trigger's dedicated
    /// recorder (General tab) — kept separate from `recordedShortcut` /
    /// `isRecordingShortcut` above so recording one control never clobbers
    /// an in-progress draft in the other.
    var recordedSearchPaletteShortcut: RecordedShortcut?
    var isRecordingSearchPaletteShortcut: Bool = false {
        didSet { syncRecordingSessionGate() }
    }
    var searchPaletteConflictMessage: String?
    /// Palette-scoped mirror of `saveErrorMessage` — the General tab's card
    /// shows this instead of the shared property so a persistence failure
    /// there is never confused with (or masked by) one that happened on the
    /// Shortcuts tab, and vice versa.
    var searchPaletteSaveErrorMessage: String?
    var recipeFeedback: RecipeFeedback?
    var pendingRecipeImport: WinkRecipeImportPlanner.ImportPlan?
    var usageCounts: [UUID: Int] = [:]
    var lastUsed: [UUID: Date] = [:]

    private let shortcutStore: ShortcutStore
    private let shortcutManager: ShortcutManager
    private let usageTracker: (any UsageTracking)?
    @ObservationIgnored private var usageRefreshGeneration: UInt64 = 0
    private let onShortcutConfigurationChange: @MainActor () -> Void
    private let shortcutValidator = ShortcutValidator()
    private let recipeCodec: WinkRecipeCodec
    private let recipeImportPlanner: WinkRecipeImportPlanner
    private let recipeTransferClient: RecipeTransferClient
    private let appBundleLocator: AppBundleLocator

    init(
        shortcutStore: ShortcutStore,
        shortcutManager: ShortcutManager,
        usageTracker: (any UsageTracking)? = nil,
        recipeCodec: WinkRecipeCodec = WinkRecipeCodec(),
        recipeImportPlanner: WinkRecipeImportPlanner = WinkRecipeImportPlanner(),
        recipeTransferClient: RecipeTransferClient = .live,
        appBundleLocator: AppBundleLocator = AppBundleLocator(),
        onShortcutConfigurationChange: @escaping @MainActor () -> Void = {}
    ) {
        self.shortcutStore = shortcutStore
        self.shortcutManager = shortcutManager
        self.usageTracker = usageTracker
        self.recipeCodec = recipeCodec
        self.recipeImportPlanner = recipeImportPlanner
        self.recipeTransferClient = recipeTransferClient
        self.appBundleLocator = appBundleLocator
        self.onShortcutConfigurationChange = onShortcutConfigurationChange
        self.shortcuts = shortcutStore.shortcuts
        observeShortcutStore()
        Task { await refreshUsageCounts() }
    }

    func addShortcut() {
        guard !selectedAppName.isEmpty,
              !selectedBundleIdentifier.isEmpty,
              let recordedShortcut else {
            return
        }

        let candidate = AppShortcut(
            appName: selectedAppName,
            bundleIdentifier: selectedBundleIdentifier,
            keyEquivalent: recordedShortcut.keyEquivalent,
            modifierFlags: recordedShortcut.modifierFlags,
            target: selectedBundleIdentifier == AppShortcut.frontmostTargetSentinelBundleIdentifier
                ? .frontmostApp
                : nil
        )

        if let conflict = shortcutValidator.conflict(for: candidate, in: shortcuts) {
            conflictMessage = conflictMessageText(for: conflict)
            return
        }

        var updated = shortcuts
        updated.append(candidate)
        guard persist(updated) else { return }
        onShortcutConfigurationChange()
        conflictMessage = nil
        resetDraft()
        Task { await refreshUsageCounts() }
    }

    /// The #356 search-palette trigger, if one is currently recorded. Not
    /// rendered in the per-app "Your Shortcuts" list (it targets no app) —
    /// see `ShortcutsTabView`'s `visibleShortcuts` filter — but it lives in
    /// the same `shortcuts` array so `ShortcutValidator` and the trigger
    /// index treat it exactly like any other binding for conflict detection
    /// and dispatch.
    var searchPaletteShortcut: AppShortcut? {
        shortcuts.first(where: \.isSearchPaletteTarget)
    }

    /// Records (or re-records) the search-palette trigger. Reuses the
    /// candidate's existing id on a re-record so this replaces the binding
    /// in place instead of accumulating duplicate rows.
    func commitSearchPaletteShortcut(_ recorded: RecordedShortcut) {
        let candidate = AppShortcut(
            id: searchPaletteShortcut?.id ?? UUID(),
            appName: AppShortcut.searchPaletteTargetStableName,
            bundleIdentifier: AppShortcut.searchPaletteTargetSentinelBundleIdentifier,
            keyEquivalent: recorded.keyEquivalent,
            modifierFlags: recorded.modifierFlags,
            target: .searchPalette
        )

        if let conflict = shortcutValidator.conflict(for: candidate, in: shortcuts) {
            searchPaletteConflictMessage = conflictMessageText(for: conflict)
            recordedSearchPaletteShortcut = nil
            return
        }

        var updated = shortcuts
        if let index = updated.firstIndex(where: { $0.id == candidate.id }) {
            updated[index] = candidate
        } else {
            updated.append(candidate)
        }
        // persist() sets the shared saveErrorMessage either way; mirror it
        // into the palette-scoped copy so the General tab's card shows its
        // own failure instead of a stale/unrelated message that happened to
        // land on the Shortcuts tab.
        guard persist(updated) else {
            searchPaletteSaveErrorMessage = saveErrorMessage
            recordedSearchPaletteShortcut = nil
            return
        }
        onShortcutConfigurationChange()
        searchPaletteConflictMessage = nil
        searchPaletteSaveErrorMessage = nil
        recordedSearchPaletteShortcut = nil
    }

    func setSearchPaletteEnabled(_ enabled: Bool) {
        guard let index = shortcuts.firstIndex(where: \.isSearchPaletteTarget),
              shortcuts[index].isEnabled != enabled else { return }
        var updated = shortcuts
        updated[index].isEnabled = enabled
        guard persist(updated) else {
            searchPaletteSaveErrorMessage = saveErrorMessage
            return
        }
        onShortcutConfigurationChange()
        searchPaletteSaveErrorMessage = nil
    }

    func removeSearchPaletteShortcut() {
        guard let id = searchPaletteShortcut?.id else { return }
        removeShortcut(id: id)
        // removeShortcut(id:) is shared with the per-app list and calls
        // persist() itself; mirror its outcome the same way as above.
        searchPaletteSaveErrorMessage = saveErrorMessage
    }

    /// #417: while either recorder is live, matched chords are consumed but
    /// not dispatched (`ShortcutManager.setRecordingSessionActive`) so an
    /// already-bound chord pressed mid-recording cannot toggle its target
    /// over the Settings window. The manager ignores same-value calls, so
    /// SwiftUI re-writing a binding with an unchanged value is a no-op.
    private func syncRecordingSessionGate() {
        shortcutManager.setRecordingSessionActive(
            isRecordingShortcut || isRecordingSearchPaletteShortcut
        )
    }

    func removeShortcut(id: UUID) {
        let updated = shortcuts.filter { $0.id != id }
        guard persist(updated) else { return }
        onShortcutConfigurationChange()
        if let usageTracker {
            Task {
                await usageTracker.deleteUsage(shortcutId: id)
                await refreshUsageCounts()
            }
        }
    }

    func moveShortcut(from source: IndexSet, to destination: Int) {
        var updated = shortcuts
        updated.moveItems(from: source, to: destination)
        guard persist(updated) else { return }
        onShortcutConfigurationChange()
    }

    /// Moves the shortcut identified by `id` to an insertion offset in the
    /// currently visible shortcut list.
    func reorderShortcut(draggedID id: UUID, toVisibleOffset offset: Int, visibleShortcutIDs: [UUID]) {
        guard let fromIndex = shortcuts.firstIndex(where: { $0.id == id }),
              visibleShortcutIDs.contains(id) else {
            return
        }

        let clampedOffset = min(max(offset, 0), visibleShortcutIDs.count)
        let destination: Int
        if clampedOffset == visibleShortcutIDs.count {
            guard let lastVisibleID = visibleShortcutIDs.last,
                  let lastVisibleIndex = shortcuts.firstIndex(where: { $0.id == lastVisibleID }) else {
                return
            }
            destination = lastVisibleIndex + 1
        } else {
            let destinationID = visibleShortcutIDs[clampedOffset]
            guard destinationID != id,
                  let destinationIndex = shortcuts.firstIndex(where: { $0.id == destinationID }) else {
                return
            }
            destination = destinationIndex
        }

        guard destination != fromIndex && destination != fromIndex + 1 else {
            return
        }

        moveShortcut(from: IndexSet([fromIndex]), to: destination)
    }

    var allEnabled: Bool {
        !shortcuts.isEmpty && shortcuts.allSatisfy(\.isEnabled)
    }

    func toggleShortcutEnabled(id: UUID) {
        guard let index = shortcuts.firstIndex(where: { $0.id == id }) else { return }
        var updated = shortcuts
        updated[index].isEnabled.toggle()
        guard persist(updated) else { return }
        onShortcutConfigurationChange()
    }

    func setFrontmostBehaviorOverride(id: UUID, behavior: FrontmostTargetBehavior?) {
        guard let index = shortcuts.firstIndex(where: { $0.id == id }),
              shortcuts[index].frontmostBehaviorOverride != behavior else { return }
        var updated = shortcuts
        updated[index].frontmostBehaviorOverride = behavior
        guard persist(updated) else { return }
        onShortcutConfigurationChange()
    }

    func setHoldAction(id: UUID, holdAction: HoldAction?) {
        guard let index = shortcuts.firstIndex(where: { $0.id == id }),
              shortcuts[index].holdAction != holdAction else { return }
        var updated = shortcuts
        updated[index].holdAction = holdAction
        guard persist(updated) else { return }
        onShortcutConfigurationChange()
    }

    func setAllEnabled(_ enabled: Bool) {
        var updated = shortcuts
        for index in updated.indices {
            updated[index].isEnabled = enabled
        }
        guard persist(updated) else { return }
        onShortcutConfigurationChange()
    }

    func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundle = Bundle(url: url),
              let bundleIdentifier = bundle.bundleIdentifier else {
            return
        }

        selectedAppName = url.deletingPathExtension().lastPathComponent
        selectedBundleIdentifier = bundleIdentifier
    }

    func clearRecordedShortcut() {
        recordedShortcut = nil
        isRecordingShortcut = false
    }

    /// Recipes are a portable set of app bindings to share with others — the
    /// search-palette trigger is a local device preference (like Hyper Key
    /// enablement or the frontmost-exceptions list), not an app binding, so
    /// it never travels in an exported `.winkrecipe`.
    private var exportableShortcuts: [AppShortcut] {
        shortcuts.filter { !$0.isSearchPaletteTarget }
    }

    func exportRecipeData() throws -> Data {
        try recipeCodec.encode(shortcuts: exportableShortcuts)
    }

    func exportRecipes() {
        do {
            let data = try exportRecipeData()
            guard let url = try recipeTransferClient.exportData(
                "Wink.winkrecipe",
                data
            ) else {
                return
            }

            recipeFeedback = .success(
                String(
                    localized: "Exported \(exportableShortcuts.count) shortcuts to \(url.lastPathComponent)",
                    bundle: WinkResourceBundle.bundle
                )
            )
        } catch {
            recipeFeedback = .error(
                String(localized: "Failed to export recipe: \(error.localizedDescription)", bundle: WinkResourceBundle.bundle)
            )
        }
    }

    func importRecipes(using appListProvider: AppListProvider) async {
        do {
            await appListProvider.forceRefreshAndWait()
            guard let data = try recipeTransferClient.importData() else {
                return
            }
            try beginImport(from: data, installedApps: appListProvider.allApps)
        } catch {
            pendingRecipeImport = nil
            recipeFeedback = .error(
                String(localized: "Failed to import recipe: \(error.localizedDescription)", bundle: WinkResourceBundle.bundle)
            )
        }
    }

    func beginImport(from data: Data, installedApps: [AppEntry]) throws {
        let recipe = try recipeCodec.decode(data)
        let importCatalog = importCatalog(for: recipe, installedApps: installedApps)
        let plan = recipeImportPlanner.planImport(
            recipe: recipe,
            existingShortcuts: shortcuts,
            installedApps: importCatalog
        )
        conflictMessage = nil
        pendingRecipeImport = plan
        recipeFeedback = .success(
            String(
                localized: "Import preview ready: \(plan.readyEntries.count) ready, \(plan.conflictEntries.count) conflicts, \(plan.unresolvedEntries.count) unresolved",
                bundle: WinkResourceBundle.bundle
            )
        )
    }

    func applyPendingImport(
        strategy: WinkRecipeImportPlanner.ConflictResolutionStrategy
    ) {
        guard let pendingRecipeImport else {
            return
        }

        let updatedShortcuts = recipeImportPlanner.applying(
            plan: pendingRecipeImport,
            to: shortcuts,
            strategy: strategy
        )

        // Keep the pending import on failure so the user can retry.
        guard persist(updatedShortcuts) else { return }
        onShortcutConfigurationChange()
        conflictMessage = nil
        self.pendingRecipeImport = nil
        let actualImportedCount = Set(updatedShortcuts.map(\.id))
        let importedEntryCount = pendingRecipeImport.entries.count { entry in
            actualImportedCount.contains(entry.imported.id)
        }
        recipeFeedback = .success(
            String(localized: "Imported \(importedEntryCount) shortcuts", bundle: WinkResourceBundle.bundle)
        )
        Task { await refreshUsageCounts() }
    }

    func discardPendingRecipeImport() {
        pendingRecipeImport = nil
    }

    /// Fire-and-forget wrapper for lifecycle triggers (tab selection, app
    /// reactivation) that have no async context of their own.
    func scheduleUsageRefresh() {
        Task { await refreshUsageCounts() }
    }

    func refreshUsageCounts() async {
        guard let usageTracker else { return }
        usageRefreshGeneration &+= 1
        let generation = usageRefreshGeneration
        async let counts = usageTracker.usageCounts(days: 7)
        async let lastUsedMap = usageTracker.lastUsedPerShortcut()
        let fetchedCounts = await counts
        let fetchedLastUsed = await lastUsedMap
        // A newer refresh owns the published maps; dropping the stale result
        // keeps usageCounts/lastUsed from mixing two different fetches.
        guard generation == usageRefreshGeneration else { return }
        usageCounts = fetchedCounts
        lastUsed = fetchedLastUsed
    }

    /// Shared by the per-app composer and the search-palette recorder —
    /// same wording either way, and `displayAppName` already resolves a
    /// pseudo-target's sentinel bundle (e.g. a colliding search-palette
    /// trigger) to its localized label.
    private func conflictMessageText(for conflict: ShortcutConflict) -> String {
        String(
            localized: "Conflict: \(conflict.existingShortcut.displayAppName) already uses \(conflict.existingShortcut.modifierFlags.joined(separator: "+"))+\(conflict.existingShortcut.keyEquivalent.uppercased())",
            bundle: WinkResourceBundle.bundle
        )
    }

    /// Saves through the manager (disk first, then in-memory store). On
    /// failure the editor list is reverted to the canonical store contents and
    /// the error is surfaced via `saveErrorMessage` instead of silently
    /// showing state that would not survive a relaunch.
    private func persist(_ updated: [AppShortcut]) -> Bool {
        do {
            try shortcutManager.save(shortcuts: updated)
            shortcuts = updated
            saveErrorMessage = nil
            return true
        } catch {
            shortcuts = shortcutStore.shortcuts
            saveErrorMessage = error.localizedDescription
            return false
        }
    }

    private func observeShortcutStore() {
        withObservationTracking {
            _ = shortcutStore.shortcuts
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }

                let latestShortcuts = self.shortcutStore.shortcuts
                if self.shortcuts != latestShortcuts {
                    self.shortcuts = latestShortcuts
                    await self.refreshUsageCounts()
                }

                self.observeShortcutStore()
            }
        }
    }

    private func resetDraft() {
        selectedAppName = ""
        selectedBundleIdentifier = ""
        recordedShortcut = nil
        isRecordingShortcut = false
    }

    private func importCatalog(
        for recipe: WinkRecipe,
        installedApps: [AppEntry]
    ) -> [AppEntry] {
        var appsByBundleIdentifier = Dictionary(
            uniqueKeysWithValues: installedApps.map { ($0.bundleIdentifier, $0) }
        )

        for recipeShortcut in recipe.shortcuts {
            guard appsByBundleIdentifier[recipeShortcut.bundleIdentifier] == nil,
                  let applicationURL = appBundleLocator.applicationURL(
                      for: recipeShortcut.bundleIdentifier
                  ) else {
                continue
            }

            let bundle = Bundle(url: applicationURL)
            let appName = (bundle?.infoDictionary?["CFBundleName"] as? String)
                ?? (bundle?.infoDictionary?["CFBundleDisplayName"] as? String)
                ?? applicationURL.deletingPathExtension().lastPathComponent

            appsByBundleIdentifier[recipeShortcut.bundleIdentifier] = AppEntry(
                id: recipeShortcut.bundleIdentifier,
                name: appName,
                url: applicationURL
            )
        }

        return Array(appsByBundleIdentifier.values)
    }
}

private extension Array {
    mutating func moveItems(from source: IndexSet, to destination: Int) {
        guard !source.isEmpty else { return }

        let movedItems = source.map { self[$0] }
        for index in source.reversed() {
            remove(at: index)
        }

        let adjustedDestination = destination - source.filter { $0 < destination }.count
        insert(contentsOf: movedItems, at: adjustedDestination)
    }
}

private func recipeContentTypes(includeLegacyImport: Bool) -> [UTType] {
    var contentTypes: [UTType] = []

    if let winkRecipeType = UTType(filenameExtension: "winkrecipe") {
        contentTypes.append(winkRecipeType)
    }

    if includeLegacyImport,
       let quickeyRecipeType = UTType(filenameExtension: "quickeyrecipe") {
        contentTypes.append(quickeyRecipeType)
    }

    contentTypes.append(.json)
    return contentTypes
}
