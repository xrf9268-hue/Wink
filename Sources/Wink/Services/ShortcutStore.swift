import Foundation
import Observation

@MainActor
@Observable
final class ShortcutStore {
    private(set) var shortcuts: [AppShortcut] = []
    /// Monotonic ownership boundary for consumers that start asynchronous
    /// work from one whole shortcut configuration. Observation callbacks are
    /// intentionally delivered later; this counter advances synchronously in
    /// the same main-actor mutation so a result can reject stale ownership
    /// without depending on callback scheduling order.
    @ObservationIgnored private(set) var configurationRevision = 0

    func replaceAll(with shortcuts: [AppShortcut]) {
        configurationRevision &+= 1
        self.shortcuts = shortcuts
    }

    func add(_ shortcut: AppShortcut) {
        configurationRevision &+= 1
        shortcuts.append(shortcut)
    }

    func remove(id: UUID) {
        guard shortcuts.contains(where: { $0.id == id }) else { return }
        configurationRevision &+= 1
        shortcuts.removeAll { $0.id == id }
    }
}
