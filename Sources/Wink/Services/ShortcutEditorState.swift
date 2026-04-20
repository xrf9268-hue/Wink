import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class ShortcutEditorState {
    var shortcuts: [AppShortcut] = []
    var selectedAppName: String = ""
    var selectedBundleIdentifier: String = ""
    var recordedShortcut: RecordedShortcut?
    var isRecordingShortcut: Bool = false
    var conflictMessage: String?
    var usageCounts: [UUID: Int] = [:]

    private let shortcutStore: ShortcutStore
    private let shortcutManager: ShortcutManager
    private let usageTracker: UsageTracker?
    private let onShortcutConfigurationChange: @MainActor () -> Void
    private let shortcutValidator = ShortcutValidator()

    init(
        shortcutStore: ShortcutStore,
        shortcutManager: ShortcutManager,
        usageTracker: UsageTracker? = nil,
        onShortcutConfigurationChange: @escaping @MainActor () -> Void = {}
    ) {
        self.shortcutStore = shortcutStore
        self.shortcutManager = shortcutManager
        self.usageTracker = usageTracker
        self.onShortcutConfigurationChange = onShortcutConfigurationChange
        self.shortcuts = shortcutStore.shortcuts
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
            modifierFlags: recordedShortcut.modifierFlags
        )

        if let conflict = shortcutValidator.conflict(for: candidate, in: shortcuts) {
            conflictMessage = "Conflict: \(conflict.existingShortcut.appName) already uses \(conflict.existingShortcut.modifierFlags.joined(separator: "+"))+\(conflict.existingShortcut.keyEquivalent.uppercased())"
            return
        }

        var updated = shortcuts
        updated.append(candidate)
        shortcuts = updated
        shortcutManager.save(shortcuts: updated)
        onShortcutConfigurationChange()
        conflictMessage = nil
        resetDraft()
        Task { await refreshUsageCounts() }
    }

    func removeShortcut(id: UUID) {
        let updated = shortcuts.filter { $0.id != id }
        shortcuts = updated
        shortcutManager.save(shortcuts: updated)
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
        shortcuts = updated
        shortcutManager.save(shortcuts: updated)
        onShortcutConfigurationChange()
    }

    var allEnabled: Bool {
        !shortcuts.isEmpty && shortcuts.allSatisfy(\.isEnabled)
    }

    func toggleShortcutEnabled(id: UUID) {
        guard let index = shortcuts.firstIndex(where: { $0.id == id }) else { return }
        shortcuts[index].isEnabled.toggle()
        shortcutManager.save(shortcuts: shortcuts)
        onShortcutConfigurationChange()
    }

    func setAllEnabled(_ enabled: Bool) {
        for index in shortcuts.indices {
            shortcuts[index].isEnabled = enabled
        }
        shortcutManager.save(shortcuts: shortcuts)
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

    func refreshUsageCounts() async {
        guard let usageTracker else { return }
        usageCounts = await usageTracker.usageCounts(days: 7)
    }

    private func resetDraft() {
        selectedAppName = ""
        selectedBundleIdentifier = ""
        recordedShortcut = nil
        isRecordingShortcut = false
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
