import AppKit
import Foundation

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var shortcuts: [AppShortcut] = []
    @Published var selectedAppName: String = ""
    @Published var selectedBundleIdentifier: String = ""
    @Published var recordedShortcut: RecordedShortcut?
    @Published var isRecordingShortcut: Bool = false
    @Published var accessibilityGranted: Bool = false
    @Published var conflictMessage: String?

    private let shortcutStore: ShortcutStore
    private let shortcutManager: ShortcutManager
    private let usageTracker: UsageTracker?
    private let appBundleLocator = AppBundleLocator()
    private let shortcutValidator = ShortcutValidator()

    init(shortcutStore: ShortcutStore, shortcutManager: ShortcutManager, usageTracker: UsageTracker? = nil) {
        self.shortcutStore = shortcutStore
        self.shortcutManager = shortcutManager
        self.usageTracker = usageTracker
        self.shortcuts = shortcutStore.shortcuts
        self.accessibilityGranted = shortcutManager.hasAccessibilityAccess()
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
        conflictMessage = nil
        resetDraft()
    }

    func removeShortcut(id: UUID) {
        let updated = shortcuts.filter { $0.id != id }
        shortcuts = updated
        shortcutManager.save(shortcuts: updated)
        if let usageTracker {
            Task { await usageTracker.deleteUsage(shortcutId: id) }
        }
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

    func revealApplication() {
        guard let url = appBundleLocator.applicationURL(for: selectedBundleIdentifier) else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func refreshPermissions() {
        accessibilityGranted = shortcutManager.hasAccessibilityAccess()
    }

    func clearRecordedShortcut() {
        recordedShortcut = nil
        isRecordingShortcut = false
    }

    private func resetDraft() {
        selectedAppName = ""
        selectedBundleIdentifier = ""
        recordedShortcut = nil
        isRecordingShortcut = false
    }
}
