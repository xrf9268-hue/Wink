import AppKit
import Foundation

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var shortcuts: [AppShortcut] = []
    @Published var selectedAppName: String = ""
    @Published var selectedBundleIdentifier: String = ""
    @Published var keyEquivalent: String = ""
    @Published var modifierFlagsText: String = "command,option"

    private let shortcutStore: ShortcutStore
    private let shortcutManager: ShortcutManager

    init(shortcutStore: ShortcutStore, shortcutManager: ShortcutManager) {
        self.shortcutStore = shortcutStore
        self.shortcutManager = shortcutManager
        self.shortcuts = shortcutStore.shortcuts
    }

    func addShortcut() {
        let modifiers = modifierFlagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !selectedAppName.isEmpty,
              !selectedBundleIdentifier.isEmpty,
              !keyEquivalent.isEmpty else {
            return
        }

        var updated = shortcuts
        updated.append(
            AppShortcut(
                appName: selectedAppName,
                bundleIdentifier: selectedBundleIdentifier,
                keyEquivalent: keyEquivalent,
                modifierFlags: modifiers
            )
        )
        shortcuts = updated
        shortcutManager.save(shortcuts: updated)
        resetDraft()
    }

    func removeShortcut(id: UUID) {
        let updated = shortcuts.filter { $0.id != id }
        shortcuts = updated
        shortcutManager.save(shortcuts: updated)
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

    private func resetDraft() {
        selectedAppName = ""
        selectedBundleIdentifier = ""
        keyEquivalent = ""
        modifierFlagsText = "command,option"
    }
}
