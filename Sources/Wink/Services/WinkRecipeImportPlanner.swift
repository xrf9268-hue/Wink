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
        let frontmostBehaviorOverride: FrontmostTargetBehavior?
        let holdAction: HoldAction?
        let target: ShortcutTarget?
        let resolution: AppResolution

        var isUnresolved: Bool {
            resolution == .unresolved
        }

        /// `resolvedAppName` resolved for display: the frontmost-app
        /// pseudo-target's stable persisted value renders as its localized
        /// label, matching `AppShortcut.displayAppName`. Every other entry's
        /// `resolvedAppName` is already display-ready.
        var displayAppName: String {
            target == .frontmostApp ? AppShortcut.frontmostTargetDisplayName : resolvedAppName
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
                isEnabled: isEnabled,
                frontmostBehaviorOverride: frontmostBehaviorOverride,
                target: target,
                holdAction: holdAction
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
            // The #356 search-palette trigger is a local device preference,
            // never a portable app binding — ShortcutEditorState.exportRecipeData
            // already excludes it on export, and it must never come back in
            // on import either (hand-edited recipe, or a future schema): it
            // targets no app, so every list in this app hides it, and a
            // second hidden global chord would be undeletable through any
            // UI. Skip it before planning so it never appears as ready,
            // conflicting, or unresolved.
            guard shortcut.shortcutTarget != .searchPalette else { continue }

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

        // Frontmost-app pseudo-targets name no installed app on purpose:
        // they are always importable, keeping their sentinel identity.
        if recipeShortcut.shortcutTarget == .frontmostApp {
            return PlannedShortcut(
                id: id,
                sourceAppName: recipeShortcut.appName,
                sourceBundleIdentifier: recipeShortcut.bundleIdentifier,
                // Stable, not localized: this flows into makeAppShortcut()'s
                // persisted appName. Use `displayAppName` above for anything
                // rendered on screen.
                resolvedAppName: AppShortcut.frontmostTargetStableName,
                resolvedBundleIdentifier: AppShortcut.frontmostTargetSentinelBundleIdentifier,
                keyEquivalent: recipeShortcut.keyEquivalent,
                modifierFlags: recipeShortcut.modifierFlags,
                isEnabled: recipeShortcut.isEnabled,
                frontmostBehaviorOverride: recipeShortcut.behaviorOverride,
                holdAction: recipeShortcut.holdActionValue,
                target: .frontmostApp,
                resolution: .matchedByBundleIdentifier
            )
        }

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
                frontmostBehaviorOverride: recipeShortcut.behaviorOverride,
                holdAction: recipeShortcut.holdActionValue,
                target: recipeShortcut.shortcutTarget,
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
                frontmostBehaviorOverride: recipeShortcut.behaviorOverride,
                holdAction: recipeShortcut.holdActionValue,
                target: recipeShortcut.shortcutTarget,
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
            frontmostBehaviorOverride: recipeShortcut.behaviorOverride,
                holdAction: recipeShortcut.holdActionValue,
            target: recipeShortcut.shortcutTarget,
            resolution: .unresolved
        )
    }
}
