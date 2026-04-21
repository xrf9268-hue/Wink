import Foundation
import Testing
@testable import Wink

@Suite("WinkRecipeImportPlanner")
struct WinkRecipeImportPlannerTests {
    @Test
    func planImportClassifiesReadyConflictAndUnresolvedEntries() {
        let planner = WinkRecipeImportPlanner()
        let installedApps = [
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
        let existing = [
            AppShortcut(
                appName: "Mail",
                bundleIdentifier: "com.apple.Mail",
                keyEquivalent: "m",
                modifierFlags: ["command"]
            )
        ]
        let recipe = WinkRecipe(
            shortcuts: [
                WinkRecipeShortcut(
                    appName: "Safari",
                    bundleIdentifier: "com.apple.Safari",
                    keyEquivalent: "s",
                    modifierFlags: ["command"],
                    isEnabled: true
                ),
                WinkRecipeShortcut(
                    appName: "Terminal",
                    bundleIdentifier: "com.apple.Terminal.missing",
                    keyEquivalent: "m",
                    modifierFlags: ["command"],
                    isEnabled: true
                ),
                WinkRecipeShortcut(
                    appName: "Ghostty",
                    bundleIdentifier: "com.mitchellh.ghostty",
                    keyEquivalent: "g",
                    modifierFlags: ["command"],
                    isEnabled: true
                ),
            ]
        )

        let plan = planner.planImport(
            recipe: recipe,
            existingShortcuts: existing,
            installedApps: installedApps
        )

        #expect(plan.readyEntries.count == 1)
        #expect(plan.conflictEntries.count == 1)
        #expect(plan.unresolvedEntries.count == 1)
        #expect(plan.entries[0].imported.resolution == .matchedByBundleIdentifier)
        #expect(plan.entries[1].imported.resolution == .matchedByAppName)
        #expect(plan.entries[2].imported.resolution == .unresolved)
    }

    @Test
    func ambiguousNameMatchesStayUnresolved() {
        let planner = WinkRecipeImportPlanner()
        let installedApps = [
            AppEntry(
                id: "com.example.notes.one",
                name: "Notes",
                url: URL(fileURLWithPath: "/Applications/Notes One.app")
            ),
            AppEntry(
                id: "com.example.notes.two",
                name: "Notes",
                url: URL(fileURLWithPath: "/Applications/Notes Two.app")
            ),
        ]
        let recipe = WinkRecipe(
            shortcuts: [
                WinkRecipeShortcut(
                    appName: "Notes",
                    bundleIdentifier: "com.example.missing",
                    keyEquivalent: "n",
                    modifierFlags: ["command"],
                    isEnabled: true
                )
            ]
        )

        let plan = planner.planImport(
            recipe: recipe,
            existingShortcuts: [],
            installedApps: installedApps
        )

        #expect(plan.unresolvedEntries.count == 1)
        #expect(plan.entries[0].imported.resolution == .unresolved)
        #expect(plan.entries[0].imported.resolvedBundleIdentifier == "com.example.missing")
    }

    @Test
    func replaceExistingSwapsConflictingBindings() {
        let planner = WinkRecipeImportPlanner()
        let existing = [
            AppShortcut(
                appName: "Terminal",
                bundleIdentifier: "com.apple.Terminal",
                keyEquivalent: "s",
                modifierFlags: ["command", "shift"]
            )
        ]
        let recipe = WinkRecipe(
            shortcuts: [
                WinkRecipeShortcut(
                    appName: "Safari",
                    bundleIdentifier: "com.apple.Safari",
                    keyEquivalent: "s",
                    modifierFlags: ["command", "shift"],
                    isEnabled: true
                )
            ]
        )
        let installedApps = [
            AppEntry(
                id: "com.apple.Safari",
                name: "Safari",
                url: URL(fileURLWithPath: "/Applications/Safari.app")
            )
        ]

        let plan = planner.planImport(
            recipe: recipe,
            existingShortcuts: existing,
            installedApps: installedApps
        )
        let updated = planner.applying(
            plan: plan,
            to: existing,
            strategy: .replaceExisting
        )

        #expect(updated.count == 1)
        #expect(updated[0].bundleIdentifier == "com.apple.Safari")
    }

    @Test
    func skipConflictsKeepsExistingBindingsUntouched() {
        let planner = WinkRecipeImportPlanner()
        let existing = [
            AppShortcut(
                appName: "Terminal",
                bundleIdentifier: "com.apple.Terminal",
                keyEquivalent: "s",
                modifierFlags: ["command", "shift"]
            )
        ]
        let recipe = WinkRecipe(
            shortcuts: [
                WinkRecipeShortcut(
                    appName: "Safari",
                    bundleIdentifier: "com.apple.Safari",
                    keyEquivalent: "s",
                    modifierFlags: ["command", "shift"],
                    isEnabled: true
                )
            ]
        )
        let installedApps = [
            AppEntry(
                id: "com.apple.Safari",
                name: "Safari",
                url: URL(fileURLWithPath: "/Applications/Safari.app")
            )
        ]

        let plan = planner.planImport(
            recipe: recipe,
            existingShortcuts: existing,
            installedApps: installedApps
        )
        let updated = planner.applying(
            plan: plan,
            to: existing,
            strategy: .skipConflicts
        )

        #expect(updated == existing)
    }

    @Test
    func unresolvedEntriesExcludeConflictingItems() {
        let planner = WinkRecipeImportPlanner()
        let existing = [
            AppShortcut(
                appName: "Mail",
                bundleIdentifier: "com.apple.Mail",
                keyEquivalent: "g",
                modifierFlags: ["command"]
            )
        ]
        let recipe = WinkRecipe(
            shortcuts: [
                WinkRecipeShortcut(
                    appName: "Ghostty",
                    bundleIdentifier: "com.mitchellh.ghostty",
                    keyEquivalent: "g",
                    modifierFlags: ["command"],
                    isEnabled: true
                )
            ]
        )

        let plan = planner.planImport(
            recipe: recipe,
            existingShortcuts: existing,
            installedApps: []
        )

        #expect(plan.conflictEntries.count == 1)
        #expect(plan.unresolvedEntries.isEmpty)
    }
}
