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
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }

        let directory = appSupport.appendingPathComponent("HotAppClone", isDirectory: true)
        if !fm.fileExists(atPath: directory.path) {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory.appendingPathComponent(fileName)
    }
}
