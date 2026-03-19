import Foundation

struct PersistenceService: Sendable {
    private let fileName = "shortcuts.json"

    func load() -> [AppShortcut] {
        guard let url = storageURL(),
              let data = try? Data(contentsOf: url) else {
            return []
        }

        return (try? JSONDecoder().decode([AppShortcut].self, from: data)) ?? []
    }

    func save(_ shortcuts: [AppShortcut]) {
        guard let url = storageURL() else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(shortcuts)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Failed to save shortcuts: \(error.localizedDescription)")
        }
    }

    private func storageURL() -> URL? {
        StoragePaths.appSupportDirectory()?.appendingPathComponent(fileName)
    }
}
