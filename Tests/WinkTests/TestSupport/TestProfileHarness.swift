import Foundation
@testable import Wink

/// Temporary Application Support directory plus a `ShortcutProfileStore`
/// wired to it. Every test that touches profile storage goes through this so
/// nothing can reach the developer's real `~/Library/Application Support/Wink`.
final class TestProfileHarness: @unchecked Sendable {
    let directory: URL
    let layout: ShortcutProfileLayout
    private let fileManager: FileManager
    private var didCleanup = false

    /// Records every diagnostic the store emits so tests can assert on the
    /// locale-stable `PROFILE_TRACE_*` tokens instead of on side effects.
    let diagnostics = CallbackRecorder<String>()

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("wink-profiles-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            fatalError("Failed to create temporary profile directory: \(error)")
        }
        self.directory = directory
        self.layout = ShortcutProfileLayout(appDirectory: directory)
    }

    deinit {
        cleanup()
    }

    func cleanup() {
        guard !didCleanup else { return }
        didCleanup = true
        try? fileManager.removeItem(at: directory)
    }

    @MainActor
    func makeStore(
        writeClient: ShortcutProfileStore.WriteClient = .live,
        idProvider: (@Sendable () -> UUID)? = nil,
        dateProvider: (@Sendable () -> Date)? = nil,
        backupIDProvider: (@Sendable () -> String)? = nil
    ) -> ShortcutProfileStore {
        let directory = self.directory
        let recorder = self.diagnostics
        return ShortcutProfileStore(
            directoryProvider: { directory },
            fileManager: fileManager,
            diagnosticClient: ShortcutProfileStore.DiagnosticClient(log: { recorder.record($0) }),
            writeClient: writeClient,
            idProvider: idProvider ?? UUID.init,
            dateProvider: dateProvider ?? { Date(timeIntervalSince1970: 1_770_000_000) },
            backupIDProvider: backupIDProvider ?? { "test-backup" }
        )
    }

    /// A loaded `ShortcutProfileState` over this harness's temporary
    /// directory. Views that only render profile rows need nothing else; the
    /// harness must outlive them so its directory is not removed underneath a
    /// later write.
    @MainActor
    func makeLoadedProfileState(shortcutManager: ShortcutManager) -> ShortcutProfileState {
        let state = ShortcutProfileState(store: makeStore(), shortcutManager: shortcutManager)
        _ = state.loadAtStartup()
        return state
    }

    // MARK: - Fixture helpers

    func writeLegacyShortcuts(_ shortcuts: [AppShortcut]) throws {
        try PersistenceService.encodeShortcuts(shortcuts).write(to: layout.mirrorURL, options: .atomic)
    }

    func writeRawLegacyShortcuts(_ contents: String) throws {
        try Data(contents.utf8).write(to: layout.mirrorURL, options: .atomic)
    }

    func writeRaw(_ contents: String, to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url, options: .atomic)
    }

    func fileExists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func data(at url: URL) -> Data? {
        try? Data(contentsOf: url)
    }

    func decodedShortcuts(at url: URL) -> [AppShortcut]? {
        guard let data = data(at: url) else { return nil }
        return try? JSONDecoder().decode([AppShortcut].self, from: data)
    }

    /// Files in `Profiles/` whose basename parses as a UUID.
    func profileDataFileIDs() -> Set<UUID> {
        let names = (try? fileManager.contentsOfDirectory(atPath: layout.profilesDirectory.path)) ?? []
        return Set(names.compactMap(ShortcutProfileLayout.profileID(forDataFileName:)))
    }

    func loadFailureCopies(in directoryURL: URL) -> [String] {
        let names = (try? fileManager.contentsOfDirectory(atPath: directoryURL.path)) ?? []
        return names.filter { $0.contains(".load-failure-") }.sorted()
    }
}

func makeTestShortcut(
    id: UUID = UUID(),
    appName: String = "Safari",
    bundleIdentifier: String = "com.apple.Safari",
    keyEquivalent: String = "s",
    modifierFlags: [String] = ["command", "option"],
    isEnabled: Bool = true
) -> AppShortcut {
    AppShortcut(
        id: id,
        appName: appName,
        bundleIdentifier: bundleIdentifier,
        keyEquivalent: keyEquivalent,
        modifierFlags: modifierFlags,
        isEnabled: isEnabled
    )
}
