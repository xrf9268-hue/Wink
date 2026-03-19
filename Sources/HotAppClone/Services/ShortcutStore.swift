import Foundation

@MainActor
final class ShortcutStore {
    private(set) var shortcuts: [AppShortcut] = []

    func replaceAll(with shortcuts: [AppShortcut]) {
        self.shortcuts = shortcuts
    }

    func add(_ shortcut: AppShortcut) {
        shortcuts.append(shortcut)
    }

    func remove(id: UUID) {
        shortcuts.removeAll { $0.id == id }
    }
}
