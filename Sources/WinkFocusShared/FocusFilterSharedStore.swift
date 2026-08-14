import Darwin
import Foundation

public enum WinkFocusSharedContract {
    public static let appGroupIdentifier = "group.com.wink.app"
    public static let stateFileName = "focus-filter-state.json"
    public static let catalogFileName = "focus-profile-catalog.json"
    public static let notificationName = "com.wink.app.focus-filter-state-changed"
}

public struct FocusProfileRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

public struct FocusProfileCatalog: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var profiles: [FocusProfileRecord]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        profiles: [FocusProfileRecord]
    ) {
        self.schemaVersion = schemaVersion
        self.profiles = profiles
    }
}

/// Durable cross-process state written by the Focus Filter extension and
/// reconciled by the main app. `manualProfileID` is the user's latest base
/// selection while the Focus overlay is active; it is never inferred from a
/// Focus name and never replaced by an arbitrary profile.
public struct FocusFilterSharedState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var profileID: UUID?
    public var pauseShortcuts: Bool
    public var manualProfileID: UUID?

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        profileID: UUID? = nil,
        pauseShortcuts: Bool = false,
        manualProfileID: UUID? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.profileID = profileID
        self.pauseShortcuts = pauseShortcuts
        self.manualProfileID = manualProfileID
    }

    public var hasFocusOverlay: Bool {
        profileID != nil || pauseShortcuts
    }
}

public enum FocusFilterSharedStoreError: Error, Equatable, Sendable {
    case containerUnavailable
    case unsupportedSchema(Int)
    case profileNotFound(UUID)
    case unreadableState
    case unreadableCatalog
    case cannotLock
    case cannotWrite
}

public enum FocusProfileCatalogDeletionResult: Equatable, Sendable {
    case updated
    case profileInUse
}

extension FocusFilterSharedStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .containerUnavailable:
            String(
                localized: "Wink cannot access its Focus Filter shared container. The app and extension must be signed with the same App Group entitlement.",
                bundle: .main
            )
        case let .unsupportedSchema(version):
            String.localizedStringWithFormat(
                String(
                    localized: "This Wink Focus Filter data uses unsupported schema version %lld.",
                    bundle: .main
                ),
                Int64(version)
            )
        case .profileNotFound:
            String(
                localized: "The Focus Filter refers to a profile that no longer exists.",
                bundle: .main
            )
        case .unreadableState:
            String(
                localized: "Wink could not read the saved Focus Filter state, so it left the current profile and pause reasons unchanged.",
                bundle: .main
            )
        case .unreadableCatalog:
            String(
                localized: "Wink could not read the Focus Filter profile catalog.",
                bundle: .main
            )
        case .cannotLock, .cannotWrite:
            String(
                localized: "Wink could not save Focus Filter state. The current profile was left unchanged.",
                bundle: .main
            )
        }
    }
}

/// File-backed App Group client shared by the main app and App Intents
/// extension. Every read-modify-write is guarded with `flock`, so a Focus
/// transition cannot race the main app's base-profile update and lose one of
/// the independent fields.
public struct FocusFilterSharedStore {
    public typealias DirectoryProvider = @Sendable () -> URL?

    struct WriteClient: Sendable {
        let write: @Sendable (Data, URL) throws -> Void

        static let live = WriteClient { data, url in
            try data.write(to: url, options: .atomic)
        }
    }

    struct DurabilityClient: Sendable {
        let flush: @Sendable (URL) throws -> Void

        static let live = DurabilityClient { url in
            let descriptor = open(url.path, O_RDONLY)
            guard descriptor >= 0 else {
                throw FocusFilterSharedStoreError.cannotWrite
            }
            defer { close(descriptor) }
            guard fcntl(descriptor, F_FULLFSYNC) != -1 else {
                throw FocusFilterSharedStoreError.cannotWrite
            }

            let directory = url.deletingLastPathComponent()
            let directoryDescriptor = open(directory.path, O_RDONLY)
            guard directoryDescriptor >= 0 else {
                throw FocusFilterSharedStoreError.cannotWrite
            }
            defer { close(directoryDescriptor) }
            guard fsync(directoryDescriptor) != -1 else {
                throw FocusFilterSharedStoreError.cannotWrite
            }
        }
    }

    private let directoryProvider: DirectoryProvider
    private let fileManager: FileManager
    private let durabilityClient: DurabilityClient
    private let writeClient: WriteClient

    public init(
        directoryProvider: @escaping DirectoryProvider = {
            FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: WinkFocusSharedContract.appGroupIdentifier
            )
        },
        fileManager: FileManager = .default
    ) {
        self.init(
            directoryProvider: directoryProvider,
            fileManager: fileManager,
            durabilityClient: .live,
            writeClient: .live
        )
    }

    init(
        directoryProvider: @escaping DirectoryProvider,
        fileManager: FileManager,
        durabilityClient: DurabilityClient,
        writeClient: WriteClient = .live
    ) {
        self.directoryProvider = directoryProvider
        self.fileManager = fileManager
        self.durabilityClient = durabilityClient
        self.writeClient = writeClient
    }

    public func loadState() throws -> FocusFilterSharedState {
        try withLock { directory in
            try loadStateUnlocked(in: directory)
        }
    }

    public func loadCatalog() throws -> FocusProfileCatalog {
        try withLock { directory in
            try loadCatalogUnlocked(in: directory)
        }
    }

    /// Main-app compare-and-apply transaction. The body runs only while the
    /// durable state still exactly matches the snapshot the caller prepared
    /// to apply, and it remains under the same cross-process lock until the
    /// caller's synchronous runtime apply is complete. This prevents the
    /// extension from committing Focus B (or deactivation) while the app is
    /// still applying an older Focus A snapshot.
    ///
    /// The body may update fields the main app owns, such as clearing the
    /// exact restore target after a successful restore. Those mutations are
    /// persisted before the lock is released. A `nil` result means the
    /// snapshot lost the race and the body was not called.
    public func updateStateIfCurrent<Result>(
        _ expectedState: FocusFilterSharedState,
        _ body: (inout FocusFilterSharedState) throws -> Result
    ) throws -> Result? {
        try withLock { directory in
            let currentState = try loadStateUnlocked(in: directory)
            guard currentState == expectedState else { return nil }

            var nextState = currentState
            let result = try body(&nextState)
            if nextState != currentState {
                try writeState(nextState, in: directory)
            }
            return result
        }
    }

    /// Extension-side transaction. A selected profile must still exist in
    /// the catalog at perform-time; stale AppEntity values fail without
    /// replacing the last valid state.
    @discardableResult
    public func applyFocusSelection(
        profileID: UUID?,
        pauseShortcuts: Bool
    ) throws -> FocusFilterSharedState {
        try withLock { directory in
            if let profileID {
                let catalog = try loadCatalogUnlocked(in: directory)
                guard catalog.profiles.contains(where: { $0.id == profileID }) else {
                    throw FocusFilterSharedStoreError.profileNotFound(profileID)
                }
            }

            var state = try loadStateUnlocked(in: directory)
            state.profileID = profileID
            state.pauseShortcuts = pauseShortcuts
            if !state.hasFocusOverlay {
                // The main app consumes this value while restoring. Keep it
                // until that transaction succeeds; never erase the only exact
                // restore target from the extension process.
            }
            try writeState(state, in: directory)
            return state
        }
    }

    /// Main-app transaction used when a Focus overlay first activates or the
    /// user changes their base selection while it remains active.
    @discardableResult
    public func setManualProfileID(_ profileID: UUID?) throws -> FocusFilterSharedState {
        try withLock { directory in
            var state = try loadStateUnlocked(in: directory)
            state.manualProfileID = profileID
            try writeState(state, in: directory)
            return state
        }
    }

    /// Persists a new manual restore target, then keeps the shared lock held
    /// while the main app synchronously applies the effective result. A Focus
    /// transition cannot land between the caller's last state check and its
    /// runtime profile apply. The body may clear the restore marker after it
    /// has made the restored active pointer durable.
    public func updateManualProfileIDAndApply<Result>(
        _ profileID: UUID,
        _ body: (inout FocusFilterSharedState) throws -> Result
    ) throws -> Result {
        try withLock { directory in
            var state = try loadStateUnlocked(in: directory)
            state.manualProfileID = profileID
            try writeState(state, in: directory)
            let persistedState = state
            let result = try body(&state)
            if state != persistedState {
                try writeState(state, in: directory)
            }
            return result
        }
    }

    /// Clears the restore target only after the main app has durably restored
    /// that exact profile. A failed restoration remains retryable at relaunch.
    @discardableResult
    public func clearManualProfileIDAfterRestore() throws -> FocusFilterSharedState {
        try setManualProfileID(nil)
    }

    public func replaceCatalog(_ catalog: FocusProfileCatalog) throws {
        guard catalog.schemaVersion == FocusProfileCatalog.currentSchemaVersion else {
            throw FocusFilterSharedStoreError.unsupportedSchema(catalog.schemaVersion)
        }
        try withLock { directory in
            let url = catalogURL(in: directory)
            try write(catalog, to: url)
            do {
                try durabilityClient.flush(url)
            } catch {
                throw FocusFilterSharedStoreError.cannotWrite
            }
        }
    }

    /// Atomically removes a profile from the extension-visible catalog only
    /// when neither the active Focus overlay nor its exact manual restore base
    /// refers to that UUID. This closes both delete orderings:
    ///
    /// - a Focus selection that wins first makes deletion fail closed;
    /// - a deletion that wins first removes the entity before a later Focus
    ///   perform can validate and persist it.
    public func replaceCatalogForDeletion(
        _ catalog: FocusProfileCatalog,
        deleting profileID: UUID
    ) throws -> FocusProfileCatalogDeletionResult {
        guard catalog.schemaVersion == FocusProfileCatalog.currentSchemaVersion else {
            throw FocusFilterSharedStoreError.unsupportedSchema(catalog.schemaVersion)
        }
        return try withLock { directory in
            let state = try loadStateUnlocked(in: directory)
            guard state.profileID != profileID,
                  state.manualProfileID != profileID else {
                return .profileInUse
            }
            let url = catalogURL(in: directory)
            try write(catalog, to: url)
            // Returning `.updated` authorizes deletion of the canonical
            // profile. The catalog removal must therefore survive a power
            // loss first; otherwise the extension could relaunch with the old
            // entity and accept a now-deleted UUID while the app is absent.
            try durabilityClient.flush(url)
            return .updated
        }
    }

    public func postStateChangedNotification() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(WinkFocusSharedContract.notificationName as CFString),
            nil,
            nil,
            true
        )
    }

    private func withLock<T>(_ body: (URL) throws -> T) throws -> T {
        guard let directory = directoryProvider() else {
            throw FocusFilterSharedStoreError.containerUnavailable
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw FocusFilterSharedStoreError.containerUnavailable
        }

        let lockURL = directory.appendingPathComponent("focus-filter.lock", isDirectory: false)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw FocusFilterSharedStoreError.cannotLock
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw FocusFilterSharedStoreError.cannotLock
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body(directory)
    }

    private func loadStateUnlocked(in directory: URL) throws -> FocusFilterSharedState {
        let url = stateURL(in: directory)
        guard fileManager.fileExists(atPath: url.path) else {
            return FocusFilterSharedState()
        }
        let state: FocusFilterSharedState
        do {
            state = try JSONDecoder().decode(
                FocusFilterSharedState.self,
                from: Data(contentsOf: url)
            )
        } catch {
            throw FocusFilterSharedStoreError.unreadableState
        }
        guard state.schemaVersion == FocusFilterSharedState.currentSchemaVersion else {
            throw FocusFilterSharedStoreError.unsupportedSchema(state.schemaVersion)
        }
        return state
    }

    private func loadCatalogUnlocked(in directory: URL) throws -> FocusProfileCatalog {
        let url = catalogURL(in: directory)
        guard fileManager.fileExists(atPath: url.path) else {
            return FocusProfileCatalog(profiles: [])
        }
        let catalog: FocusProfileCatalog
        do {
            catalog = try JSONDecoder().decode(
                FocusProfileCatalog.self,
                from: Data(contentsOf: url)
            )
        } catch {
            throw FocusFilterSharedStoreError.unreadableCatalog
        }
        guard catalog.schemaVersion == FocusProfileCatalog.currentSchemaVersion else {
            throw FocusFilterSharedStoreError.unsupportedSchema(catalog.schemaVersion)
        }
        return catalog
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try writeClient.write(encoder.encode(value), url)
        } catch {
            throw FocusFilterSharedStoreError.cannotWrite
        }
    }

    /// State mutations can authorize a later profile-pointer commit. Make the
    /// state file and its rename durable before releasing the shared lock so a
    /// power loss cannot persist the Focus profile while losing its exact
    /// manual restore target.
    private func writeState(_ state: FocusFilterSharedState, in directory: URL) throws {
        let url = stateURL(in: directory)
        try write(state, to: url)
        do {
            try durabilityClient.flush(url)
        } catch {
            throw FocusFilterSharedStoreError.cannotWrite
        }
    }

    private func stateURL(in directory: URL) -> URL {
        directory.appendingPathComponent(WinkFocusSharedContract.stateFileName, isDirectory: false)
    }

    private func catalogURL(in directory: URL) -> URL {
        directory.appendingPathComponent(WinkFocusSharedContract.catalogFileName, isDirectory: false)
    }
}
