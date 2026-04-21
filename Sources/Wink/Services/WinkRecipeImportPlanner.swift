import Foundation

struct WinkRecipeImportPlanner {
    enum AppResolution: Equatable, Sendable {
        case matchedByBundleIdentifier
        case matchedByAppName
        case unresolved
    }

    enum ConflictResolutionStrategy: Equatable, Sendable {
        case skipConflicts
        case replaceExisting
    }

    struct PlannedShortcut: Identifiable, Equatable, Sendable {
        let id: UUID
        let sourceAppName: String
        let sourceBundleIdentifier: String
        let resolvedAppName: String
        let resolvedBundleIdentifier: String
        let keyEquivalent: String
        let modifierFlags: [String]
        let isEnabled: Bool
        let resolution: AppResolution

        var isUnresolved: Bool {
            resolution == .unresolved
        }

        var displayText: String {
            ModifierFormatting.displayText(
                modifierFlags: modifierFlags,
                keyEquivalent: keyEquivalent
            )
        }

        func makeAppShortcut() -> AppShortcut {
            AppShortcut(
                id: id,
                appName: resolvedAppName,
                bundleIdentifier: resolvedBundleIdentifier,
                keyEquivalent: keyEquivalent,
                modifierFlags: modifierFlags,
                isEnabled: isEnabled
            )
        }
    }

    struct ImportEntry: Identifiable, Equatable, Sendable {
        let imported: PlannedShortcut
        let conflictingShortcut: AppShortcut?

        var id: UUID {
            imported.id
        }

        var isConflict: Bool {
            conflictingShortcut != nil
        }

        var isUnresolved: Bool {
            imported.isUnresolved
        }
    }

    struct ImportPlan: Equatable, Sendable {
        let entries: [ImportEntry]

        var readyEntries: [ImportEntry] {
            entries.filter { !$0.isConflict && !$0.isUnresolved }
        }

        var conflictEntries: [ImportEntry] {
            entries.filter(\.isConflict)
        }

        var unresolvedEntries: [ImportEntry] {
            entries.filter { $0.isUnresolved && !$0.isConflict }
        }

        func importedEntryCount(for strategy: ConflictResolutionStrategy) -> Int {
            switch strategy {
            case .skipConflicts:
                entries.filter { !$0.isConflict }.count
            case .replaceExisting:
                entries.count
            }
        }
    }

    private let shortcutValidator: ShortcutValidator
    private let idProvider: @Sendable () -> UUID

    init(
        shortcutValidator: ShortcutValidator = ShortcutValidator(),
        idProvider: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.shortcutValidator = shortcutValidator
        self.idProvider = idProvider
    }

    func planImport(
        recipe: WinkRecipe,
        existingShortcuts: [AppShortcut],
        installedApps: [AppEntry]
    ) -> ImportPlan {
        var simulatedShortcuts = existingShortcuts
        var entries: [ImportEntry] = []

        for shortcut in recipe.shortcuts {
            let planned = plannedShortcut(for: shortcut, installedApps: installedApps)
            let candidate = planned.makeAppShortcut()
            let conflict = shortcutValidator.conflict(
                for: candidate,
                in: simulatedShortcuts
            )?.existingShortcut

            entries.append(
                ImportEntry(
                    imported: planned,
                    conflictingShortcut: conflict
                )
            )

            if conflict == nil {
                simulatedShortcuts.append(candidate)
            }
        }

        return ImportPlan(entries: entries)
    }

    func applying(
        plan: ImportPlan,
        to existingShortcuts: [AppShortcut],
        strategy: ConflictResolutionStrategy
    ) -> [AppShortcut] {
        var updatedShortcuts = existingShortcuts

        if strategy == .replaceExisting {
            let conflictingIDs = Set(
                plan.conflictEntries.compactMap { $0.conflictingShortcut?.id }
            )
            updatedShortcuts.removeAll { conflictingIDs.contains($0.id) }
        }

        let entriesToImport: [ImportEntry]
        switch strategy {
        case .skipConflicts:
            entriesToImport = plan.entries.filter { !$0.isConflict }
        case .replaceExisting:
            entriesToImport = plan.entries
        }

        for entry in entriesToImport {
            let candidate = entry.imported.makeAppShortcut()
            guard shortcutValidator.conflict(
                for: candidate,
                in: updatedShortcuts
            ) == nil else {
                continue
            }
            updatedShortcuts.append(candidate)
        }

        return updatedShortcuts
    }

    private func plannedShortcut(
        for recipeShortcut: WinkRecipeShortcut,
        installedApps: [AppEntry]
    ) -> PlannedShortcut {
        let id = idProvider()

        if let matchedByBundleIdentifier = installedApps.first(where: {
            $0.bundleIdentifier == recipeShortcut.bundleIdentifier
        }) {
            return PlannedShortcut(
                id: id,
                sourceAppName: recipeShortcut.appName,
                sourceBundleIdentifier: recipeShortcut.bundleIdentifier,
                resolvedAppName: matchedByBundleIdentifier.name,
                resolvedBundleIdentifier: matchedByBundleIdentifier.bundleIdentifier,
                keyEquivalent: recipeShortcut.keyEquivalent,
                modifierFlags: recipeShortcut.modifierFlags,
                isEnabled: recipeShortcut.isEnabled,
                resolution: .matchedByBundleIdentifier
            )
        }

        let nameMatches = installedApps.filter {
            $0.name.compare(
                recipeShortcut.appName,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame
        }

        if nameMatches.count == 1, let matchedByName = nameMatches.first {
            return PlannedShortcut(
                id: id,
                sourceAppName: recipeShortcut.appName,
                sourceBundleIdentifier: recipeShortcut.bundleIdentifier,
                resolvedAppName: matchedByName.name,
                resolvedBundleIdentifier: matchedByName.bundleIdentifier,
                keyEquivalent: recipeShortcut.keyEquivalent,
                modifierFlags: recipeShortcut.modifierFlags,
                isEnabled: recipeShortcut.isEnabled,
                resolution: .matchedByAppName
            )
        }

        return PlannedShortcut(
            id: id,
            sourceAppName: recipeShortcut.appName,
            sourceBundleIdentifier: recipeShortcut.bundleIdentifier,
            resolvedAppName: recipeShortcut.appName,
            resolvedBundleIdentifier: recipeShortcut.bundleIdentifier,
            keyEquivalent: recipeShortcut.keyEquivalent,
            modifierFlags: recipeShortcut.modifierFlags,
            isEnabled: recipeShortcut.isEnabled,
            resolution: .unresolved
        )
    }
}
