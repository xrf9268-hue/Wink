import CryptoKit
import Foundation
import os.log

private let logger = Logger(subsystem: DiagnosticLog.subsystem, category: "ShortcutProfileStore")

/// Path math for the profile store. Pure and `Sendable` so the `@Sendable`
/// closures handed to `PersistenceService` can hold it.
struct ShortcutProfileLayout: Sendable, Equatable {
    static let directoryName = "Profiles"
    static let manifestFileName = "manifest.json"
    static let activePointerFileName = "active.json"
    static let mirrorDescriptorFileName = "mirror.json"
    static let mirrorFileName = "shortcuts.json"

    let appDirectory: URL

    var profilesDirectory: URL {
        appDirectory.appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    var manifestURL: URL {
        profilesDirectory.appendingPathComponent(Self.manifestFileName)
    }

    var activePointerURL: URL {
        profilesDirectory.appendingPathComponent(Self.activePointerFileName)
    }

    var mirrorDescriptorURL: URL {
        profilesDirectory.appendingPathComponent(Self.mirrorDescriptorFileName)
    }

    /// The compat mirror keeps the exact path `shortcuts.json` has always had,
    /// so the packaged-app E2E harness, the validation docs, and an older
    /// build all keep finding a configuration where they expect one.
    var mirrorURL: URL {
        appDirectory.appendingPathComponent(Self.mirrorFileName)
    }

    func profileDataURL(_ profileID: UUID) -> URL {
        profilesDirectory.appendingPathComponent("\(profileID.uuidString).json")
    }

    /// A basename that parses as a UUID is a profile data file; anything else
    /// is metadata. This is what makes orphan detection decidable without a
    /// second index.
    static func profileID(forDataFileName name: String) -> UUID? {
        guard name.hasSuffix(".json") else { return nil }
        return UUID(uuidString: String(name.dropLast(5)))
    }
}

/// Resolves the file a save must write to. A profile switch updates this box,
/// so an already-constructed `PersistenceService` follows the switch without
/// being rebuilt — and without the store itself having to be `Sendable`.
final class ActiveProfileFileLocator: @unchecked Sendable {
    private let lock = NSLock()
    private var activeProfileID: UUID?
    /// Resolved per call, never cached: `StoragePaths.appSupportDirectory()`
    /// creates the directory on demand, so resolving it eagerly would give
    /// merely constructing the store a filesystem side effect, and a cached
    /// `nil` would survive storage becoming available later.
    private let layoutProvider: @Sendable () -> ShortcutProfileLayout?

    init(layoutProvider: @escaping @Sendable () -> ShortcutProfileLayout?) {
        self.layoutProvider = layoutProvider
    }

    func setActiveProfileID(_ profileID: UUID?) {
        lock.lock()
        defer { lock.unlock() }
        activeProfileID = profileID
    }

    func currentActiveProfileID() -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        return activeProfileID
    }

    /// `nil` when storage is unavailable or no profile is active — the same
    /// signal `PersistenceService` already treats as `storageUnavailable`, so
    /// a save during a quarantined-manifest session fails loudly instead of
    /// writing somewhere arbitrary.
    func activeProfileDataURL() -> URL? {
        guard let profileID = currentActiveProfileID(), let layout = layoutProvider() else { return nil }
        return layout.profileDataURL(profileID)
    }
}

@MainActor
final class ShortcutProfileStore {
    struct DiagnosticClient: Sendable {
        let log: @Sendable (String) -> Void

        static let live = DiagnosticClient(log: DiagnosticLog.log)
    }

    /// Every disk write goes through this seam so tests can fail an individual
    /// write point and assert that the resulting on-disk state maps to exactly
    /// one recovery row.
    struct WriteClient: Sendable {
        let write: @Sendable (Data, URL) throws -> Void
        /// Writes and does not return until the bytes are on stable storage.
        ///
        /// Used for the copies that AUTHORIZE a destructive overwrite. D7
        /// deliberately adds no fsync barriers to the metadata commits, on the
        /// grounds that every on-disk combination has a defined reading and
        /// recovery is therefore total. That argument does not extend here: a
        /// preservation copy exists precisely because its contents cannot be
        /// reconstructed, so if the overwrite lands and the copy does not,
        /// nothing can recover it. `.atomic` is a rename, and a rename is not
        /// a barrier — the two writes can reach disk in either order.
        let writeDurable: @Sendable (Data, URL) throws -> Void

        // writeDurable defaults to nil and resolves in the body: CI's Swift
        // 6.1.2 SILGen crashes on non-trivial init default arguments.
        init(
            write: @escaping @Sendable (Data, URL) throws -> Void,
            writeDurable: (@Sendable (Data, URL) throws -> Void)? = nil
        ) {
            self.write = write
            self.writeDurable = writeDurable ?? write
        }

        static let live = WriteClient(
            write: { data, url in
                try data.write(to: url, options: .atomic)
            },
            writeDurable: { data, url in
                try data.write(to: url, options: .atomic)
                try WriteClient.flushToStableStorage(url)
            }
        )

        /// `F_FULLFSYNC` rather than `fsync`: on Apple platforms `fsync` only
        /// hands the blocks to the drive, which may still hold them in a
        /// volatile cache. The containing directory is synced too, because the
        /// file arrived by rename and an unsynced directory can lose the entry
        /// even when the file's own blocks are durable.
        static func flushToStableStorage(_ url: URL) throws {
            func failure(_ reason: String) -> StoreError {
                StoreError.writeFailed(path: url.path, reason: reason)
            }

            let fd = open(url.path, O_RDONLY)
            guard fd >= 0 else { throw failure("could not reopen the preserved copy to flush it") }
            defer { close(fd) }
            guard fcntl(fd, F_FULLFSYNC) != -1 else {
                throw failure("could not flush the preserved copy to stable storage")
            }

            let directory = url.deletingLastPathComponent()
            let dfd = open(directory.path, O_RDONLY)
            guard dfd >= 0 else { throw failure("could not open the containing directory to flush it") }
            defer { close(dfd) }
            guard fsync(dfd) != -1 else {
                throw failure("could not flush the containing directory")
            }
        }
    }

    enum StoreError: Error, LocalizedError, Sendable, Equatable {
        case storageUnavailable
        case writeFailed(path: String, reason: String)
        case profileNotFound(UUID)
        case profileUnreadable(id: UUID, reason: String)
        case nameRejected(ShortcutProfileNameRules.Violation)
        case profileLimitReached(limit: Int)
        case cannotDeleteLastProfile
        case manifestQuarantined
        case profileChangedDuringOperation(id: UUID)
        case usageDeletionInFlight
        case foreignMirrorChangedSinceOffer
        /// The import's canonical writes landed; only the compatibility
        /// rewrite was refused. Distinct from `writeFailed` because the
        /// user-facing meaning is opposite: something WAS changed, and a
        /// retry completes the remainder rather than repeating the whole
        /// operation.
        case importCommittedButMirrorNotRestored
        /// The import repaired the profile's data file, but the activation
        /// that finishes the recovery (the pointer commit, or what follows
        /// it) failed. Same honesty rule as the mirror case: the canonical
        /// payload IS on disk, and a retry finishes the remainder.
        case importCommittedButActivationIncomplete

        var errorDescription: String? {
            switch self {
            case .storageUnavailable:
                return "Profile storage unavailable"
            case let .writeFailed(path, reason):
                return "Failed to write profile data: path=\(path) reason=\(reason)"
            case let .profileNotFound(id):
                return "Profile not found: id=\(id.uuidString)"
            case let .profileUnreadable(id, reason):
                return "Profile could not be read: id=\(id.uuidString) reason=\(reason)"
            case let .profileChangedDuringOperation(id):
                return "Profile changed while it was being applied: id=\(id.uuidString)"
            case .usageDeletionInFlight:
                return "Usage history for one of these shortcuts is still being removed"
            case .foreignMirrorChangedSinceOffer:
                return "The file was changed again after this offer was captured"
            case .importCommittedButMirrorNotRestored:
                return "The import landed but the compatibility file could not be rewritten"
            case .importCommittedButActivationIncomplete:
                return "The import landed but activating the repaired profile did not finish"
            case let .nameRejected(violation):
                return "Profile name rejected: \(violation)"
            case let .profileLimitReached(limit):
                return "Profile limit reached: limit=\(limit)"
            case .cannotDeleteLastProfile:
                return "The last profile cannot be deleted"
            case .manifestQuarantined:
                return "Profile list is quarantined; recovery is required before changes can be saved"
            }
        }
    }

    /// A `shortcuts.json` whose bytes no longer match what Wink last wrote —
    /// in practice, an older build that still treats the file as the source of
    /// truth. Never adopted or discarded without an explicit user choice.
    struct ForeignMirror: Equatable, Sendable {
        /// The profile the mirror last described, i.e. the one the other build
        /// was actually editing — not necessarily the currently active one.
        var profileID: UUID
        /// `nil` when the foreign bytes do not decode, in which case only
        /// "keep the profile and overwrite the file" is offered.
        var shortcuts: [AppShortcut]?
        /// The bytes exactly as they were read. **Not optional**: adoption
        /// installs these rather than a re-encoding of `shortcuts`, so JSON
        /// members this build does not model survive the import — the same rule
        /// migration follows. Making it optional left a branch that re-encoded
        /// the model, which is precisely the loss this import exists to rescue
        /// from, and a type that can express the lossy state invites a caller
        /// that produces it.
        var rawBytes: Data
    }

    struct LoadedProfiles: Equatable, Sendable {
        var profiles: [ShortcutProfile]
        var activeProfileID: UUID
        var activeShortcuts: [AppShortcut]
        /// Manifest entries whose data file is missing or does not decode.
        var unreadableProfileIDs: Set<UUID>
        /// `<uuid>.json` files with no manifest entry. Never auto-imported.
        var orphanProfileIDs: Set<UUID>
        /// Shortcut IDs that appear in more than one profile. Reported, not
        /// repaired: dispatch is unaffected because per-profile uniqueness is
        /// still enforced; only Insights attribution merges.
        var duplicateShortcutIDs: Set<UUID>
        var foreignMirror: ForeignMirror?
        /// True when a startup mirror repair (a missing compat file being
        /// rewritten, a stale one being replaced, or its descriptor being
        /// corrected) was refused: startup is still `.ready` — the mirror is
        /// derived data — but the state layer must surface the same caveat
        /// every other mirror-rewriting path reports.
        var compatMirrorStale: Bool = false
        /// Set when first-run migration could not read the legacy
        /// `shortcuts.json`. The store itself is healthy and an empty Default
        /// profile exists, but the user's previous configuration was never
        /// consciously recovered or discarded, so this is surfaced rather than
        /// presented as an ordinary empty install.
        var legacyMigrationFailure: LegacyMigrationFailure?
    }

    struct LegacyMigrationFailure: Equatable, Sendable {
        var preservedCopyPath: String?
    }

    /// The total interpretation of the four on-disk files. Every state maps to
    /// exactly one case, and every failing case arms **zero** shortcuts — an
    /// unreadable configuration must never fall through to a different
    /// profile's bindings.
    enum LoadState: Equatable, Sendable {
        case ready(LoadedProfiles)
        case storageUnavailable
        case manifestUnreadable(preservedCopyPath: String?)
        /// The manifest is fine but the active profile cannot be determined
        /// without guessing. The UI must ask; it must never auto-select.
        case activeProfileAmbiguous(profiles: [ShortcutProfile], preservedCopyPath: String?)
        case activeProfileUnreadable(
            profiles: [ShortcutProfile],
            activeProfileID: UUID,
            preservedCopyPath: String?,
            /// Set only when the active profile has no data file *and* a
            /// legacy `shortcuts.json` still parses — an interrupted first-run
            /// migration. The user is offered that import rather than a dead
            /// end; nothing is adopted without the choice.
            importableMirror: ForeignMirror? = nil
        )
    }

    private let directoryProvider: @Sendable () -> URL?
    private let fileManager: FileManager
    private let diagnosticClient: DiagnosticClient
    private let writeClient: WriteClient
    private let idProvider: @Sendable () -> UUID
    private let dateProvider: @Sendable () -> Date
    private let backupIDProvider: @Sendable () -> String

    let locator: ActiveProfileFileLocator

    /// Last successfully loaded manifest. `nil` while quarantined, which is
    /// what blocks every mutation until the user chooses to recover.
    private(set) var manifest: ShortcutProfileManifest?

    /// The profile `active.json` names, whether or not its data could be
    /// loaded. The locator is deliberately cleared when the data is
    /// unreadable — it decides where saves go, and there is nowhere safe to
    /// send them — but "which profile is the pointer on" is a different
    /// question, and deletion has to ask that one or it will remove the
    /// pointed profile without committing a successor.
    private(set) var pointedProfileID: UUID?

    /// False when the active pointer could not be written during a repair.
    /// The single-profile case stays usable, but a second profile cannot be
    /// created until the pointer exists — with two profiles and no pointer,
    /// the next launch has nothing to resolve.
    private(set) var activePointerIsDurable = true

    init(
        directoryProvider: @escaping @Sendable () -> URL? = { StoragePaths.appSupportDirectory() },
        fileManager: FileManager = .default,
        diagnosticClient: DiagnosticClient = .live,
        writeClient: WriteClient = .live,
        idProvider: @escaping @Sendable () -> UUID = UUID.init,
        dateProvider: @escaping @Sendable () -> Date = Date.init,
        backupIDProvider: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.directoryProvider = directoryProvider
        self.fileManager = fileManager
        self.diagnosticClient = diagnosticClient
        self.writeClient = writeClient
        self.idProvider = idProvider
        self.dateProvider = dateProvider
        self.backupIDProvider = backupIDProvider
        self.locator = ActiveProfileFileLocator(
            layoutProvider: { directoryProvider().map { ShortcutProfileLayout(appDirectory: $0) } }
        )
    }

    /// Resolved on demand — see `ActiveProfileFileLocator.layoutProvider`.
    private var layout: ShortcutProfileLayout? {
        directoryProvider().map { ShortcutProfileLayout(appDirectory: $0) }
    }

    // MARK: - Persistence seam for the active profile

    /// The `PersistenceService` every ordinary shortcut save goes through. It
    /// follows profile switches via the locator and carries the mirror write
    /// as a derived copy, so `ShortcutManager.save(shortcuts:)` needs no
    /// profile knowledge at all.
    /// `onMirrorWriteOutcome` fires on every save with whether the compat
    /// rewrite landed — the same signal every other mirror-rewriting path
    /// reports through its caveat, in BOTH directions: a refusal is the
    /// caller's one chance to warn (the save itself has committed; derived
    /// data never fails it), and a later success is what lets the caller
    /// clear a warning that no longer describes the disk.
    func makeActiveProfilePersistenceService(
        onMirrorWriteOutcome: (@Sendable (Bool) -> Void)? = nil
    ) -> PersistenceService {
        let locator = self.locator
        let directoryProvider = self.directoryProvider
        let writeClient = self.writeClient
        let diagnosticClient = self.diagnosticClient

        return PersistenceService(
            storageURLProvider: { locator.activeProfileDataURL() },
            diagnosticClient: PersistenceService.DiagnosticClient(log: diagnosticClient.log),
            backupIDProvider: backupIDProvider,
            derivedCopyWriter: { data in
                guard
                    let directory = directoryProvider(),
                    let profileID = locator.currentActiveProfileID()
                else { return }
                let layout = ShortcutProfileLayout(appDirectory: directory)
                let restored = Self.writeMirror(
                    data: data,
                    profileID: profileID,
                    layout: layout,
                    writeClient: writeClient,
                    diagnosticClient: diagnosticClient
                )
                onMirrorWriteOutcome?(restored)
            }
        )
    }

    // MARK: - Load

    func load() -> LoadState {
        guard let layout else {
            manifest = nil
            pointedProfileID = nil
            locator.setActiveProfileID(nil)
            return .storageUnavailable
        }

        do {
            try fileManager.createDirectory(at: layout.profilesDirectory, withIntermediateDirectories: true)
        } catch {
            log("Failed to create profiles directory: path=\(layout.profilesDirectory.path) reason=\(error.localizedDescription)")
            manifest = nil
            locator.setActiveProfileID(nil)
            return .storageUnavailable
        }

        guard fileManager.fileExists(atPath: layout.manifestURL.path) else {
            return migrate(layout: layout)
        }

        guard let manifestData = try? Data(contentsOf: layout.manifestURL) else {
            manifest = nil
            locator.setActiveProfileID(nil)
            log("PROFILE_TRACE_MANIFEST_UNREADABLE reason=read_failed")
            return .manifestUnreadable(preservedCopyPath: nil)
        }

        guard
            let decodedManifest = try? Self.metadataDecoder.decode(ShortcutProfileManifest.self, from: manifestData),
            decodedManifest.schemaVersion == ShortcutProfileManifest.currentSchemaVersion,
            !decodedManifest.profiles.isEmpty,
            Set(decodedManifest.profiles.map(\.id)).count == decodedManifest.profiles.count,
            // A hand-edited or partially restored manifest can carry names the
            // create and rename paths would have rejected — empty, over the
            // length limit, or colliding. Each breaks the surfaces that address
            // a profile by the name the user reads (the picker, the menu,
            // rename), so they are load failures, exactly like a duplicate id.
            //
            // Asking `ShortcutProfileNameRules` rather than restating its
            // clauses here is the point: a rule added to creation is then
            // enforced on load for free, instead of drifting into a state only
            // a restored file can reach. `excluding` is each profile itself,
            // which must not count as its own collision.
            //
            // The 32-profile cap is deliberately NOT enforced here: existing
            // data over the cap stays usable, and `createProfile` already
            // refuses to add to it.
            Self.everyNameIsAddressable(decodedManifest.profiles)
        else {
            let preserved = preserveRejectedPayload(manifestData, originalURL: layout.manifestURL)
            manifest = nil
            locator.setActiveProfileID(nil)
            log("PROFILE_TRACE_MANIFEST_UNREADABLE reason=decode_failed preservedCopyPath=\(preserved ?? "none")")
            return .manifestUnreadable(preservedCopyPath: preserved)
        }

        manifest = decodedManifest

        let pointer = resolveActivePointer(layout: layout, manifest: decodedManifest)
        switch pointer {
        case let .resolved(profileID):
            pointedProfileID = profileID
            return loadActiveProfile(
                layout: layout,
                manifest: decodedManifest,
                activeProfileID: profileID
            )
        case let .ambiguous(preservedCopyPath):
            pointedProfileID = nil
            locator.setActiveProfileID(nil)
            log("PROFILE_TRACE_ACTIVE_AMBIGUOUS profiles=\(decodedManifest.profiles.count)")
            return .activeProfileAmbiguous(
                profiles: decodedManifest.profiles,
                preservedCopyPath: preservedCopyPath
            )
        }
    }

    /// Reads only `schemaVersion`, so a metadata file written by another
    /// build can be recognized as *understood but unsupported* rather than
    /// lumped in with corruption.
    private struct MetadataSchemaProbe: Decodable {
        let schemaVersion: Int
    }

    private enum ActivePointerResolution {
        case resolved(UUID)
        case ambiguous(preservedCopyPath: String?)
    }

    private func resolveActivePointer(
        layout: ShortcutProfileLayout,
        manifest: ShortcutProfileManifest
    ) -> ActivePointerResolution {
        var preservedCopyPath: String?

        if fileManager.fileExists(atPath: layout.activePointerURL.path),
           (try? Data(contentsOf: layout.activePointerURL)) == nil {
            // Present but unreadable. The single-profile adoption below would
            // both arm a profile this file may deliberately not have named and
            // overwrite the file while doing it — the same trade the
            // unsupported-schema branch already refuses, and for the same
            // reason: bytes this build cannot interpret may still carry a
            // meaning ("none active") that adopting silently discards. An
            // unreadable file is even less interpretable than a future schema,
            // so it cannot license a weaker response.
            log("PROFILE_TRACE_ACTIVE_UNREADABLE")
            return .ambiguous(preservedCopyPath: nil)
        }

        if let data = try? Data(contentsOf: layout.activePointerURL) {
            if
                let probe = try? Self.metadataDecoder.decode(MetadataSchemaProbe.self, from: data),
                probe.schemaVersion != ShortcutProfileActivePointer.currentSchemaVersion
            {
                // A well-formed pointer from a build this one does not
                // understand is a deliberate signal, not corruption, and a
                // future schema may mean more than "which of today's profiles"
                // — "none active", for instance. Adopting a single profile
                // here would arm bindings that build had deliberately left
                // unarmed, so fail closed regardless of profile count.
                let preserved = preserveRejectedPayload(data, originalURL: layout.activePointerURL)
                log("PROFILE_TRACE_ACTIVE_UNSUPPORTED_SCHEMA version=\(probe.schemaVersion)")
                return .ambiguous(preservedCopyPath: preserved)
            }

            if
                let pointer = try? Self.metadataDecoder.decode(ShortcutProfileActivePointer.self, from: data),
                pointer.schemaVersion == ShortcutProfileActivePointer.currentSchemaVersion
            {
                if manifest.profile(id: pointer.activeProfileID) != nil {
                    return .resolved(pointer.activeProfileID)
                }
                // Names a profile that no longer exists. Falling through to
                // another profile would arm chords the user never selected.
                return .ambiguous(preservedCopyPath: nil)
            }

            preservedCopyPath = preserveRejectedPayload(data, originalURL: layout.activePointerURL)
        }

        // Absent, or present and readable but not decodable. With exactly one
        // profile there is no other configuration this could be confused with,
        // so adopting it is a determination rather than a guess. A file that
        // could not be READ never reaches here — see above.
        if manifest.profiles.count == 1 {
            let only = manifest.profiles[0].id
            do {
                try commitActivePointer(only, layout: layout)
                activePointerIsDurable = true
            } catch {
                // Keep the profile armed — the data is readable and refusing
                // to run because of a pointer write would be a worse outcome
                // than a transient full disk deserves — but remember that no
                // durable pointer exists, because adding a second profile
                // while that is true is what turns it into ambiguous recovery
                // on the next launch.
                activePointerIsDurable = false
                log("PROFILE_TRACE_ACTIVE_POINTER_NOT_DURABLE id=\(only.uuidString)")
            }
            return .resolved(only)
        }

        return .ambiguous(preservedCopyPath: preservedCopyPath)
    }

    private func loadActiveProfile(
        layout: ShortcutProfileLayout,
        manifest: ShortcutProfileManifest,
        activeProfileID: UUID
    ) -> LoadState {
        let dataURL = layout.profileDataURL(activeProfileID)

        guard fileManager.fileExists(atPath: dataURL.path) else {
            locator.setActiveProfileID(nil)
            log("PROFILE_TRACE_UNREADABLE id=\(activeProfileID.uuidString) reason=missing preservedCopyPath=none")
            // The metadata can outlive the data it describes: atomic writes
            // rename without an fsync, so a power loss during first-run
            // migration can land manifest.json while the Default profile's
            // data rename is still in flight. Migration never re-runs once a
            // manifest exists, so without this the intact legacy file would
            // sit on disk with nothing offered to import it. Surfacing it as
            // an importable mirror reuses the path that already exists for
            // outside edits, and still requires an explicit choice.
            let resumableMirror = resumableLegacyMirror(layout: layout, activeProfileID: activeProfileID)
            return .activeProfileUnreadable(
                profiles: manifest.profiles,
                activeProfileID: activeProfileID,
                preservedCopyPath: nil,
                importableMirror: resumableMirror
            )
        }

        let activeShortcuts: [AppShortcut]
        let activeBytes: Data
        do {
            // Strict, quarantine-on-failure — the unmodified loader every
            // shortcuts.json has always used. Read ONCE: the mirror
            // classification below compares against these bytes and repairs
            // from them, and re-reading the file there would let an external
            // writer land between the two, arming one payload while the mirror
            // is repaired from another. Same rule as an explicit switch.
            let loaded = try profilePersistenceService(for: dataURL).loadWithBytes()
            activeShortcuts = loaded.shortcuts
            guard let bytes = loaded.data else {
                throw StoreError.profileUnreadable(id: activeProfileID, reason: "data file is missing")
            }
            activeBytes = bytes
        } catch {
            locator.setActiveProfileID(nil)
            let preserved = preservedCopyPath(from: error)
            log("PROFILE_TRACE_UNREADABLE id=\(activeProfileID.uuidString) reason=decode_failed preservedCopyPath=\(preserved ?? "none")")
            return .activeProfileUnreadable(
                profiles: manifest.profiles,
                activeProfileID: activeProfileID,
                preservedCopyPath: preserved
            )
        }

        locator.setActiveProfileID(activeProfileID)

        let integrity = scanIntegrity(
            layout: layout,
            manifest: manifest,
            activeProfileID: activeProfileID,
            activeShortcuts: activeShortcuts
        )
        let (foreignMirror, mirrorHealthy) = detectForeignMirror(
            layout: layout,
            activeProfileID: activeProfileID,
            activeBytes: activeBytes
        )

        return .ready(
            LoadedProfiles(
                profiles: manifest.profiles,
                activeProfileID: activeProfileID,
                activeShortcuts: activeShortcuts,
                unreadableProfileIDs: integrity.unreadable,
                orphanProfileIDs: integrity.orphans,
                duplicateShortcutIDs: integrity.duplicateShortcutIDs,
                foreignMirror: foreignMirror,
                compatMirrorStale: !mirrorHealthy,
                // Re-derived from the manifest on every launch: the failed
                // migration never runs again, so this record is the only
                // thing keeping the lost-shortcuts notice alive until the
                // user dismisses it.
                legacyMigrationFailure: manifest.legacyMigrationFailure.map {
                    LegacyMigrationFailure(preservedCopyPath: $0.preservedCopyPath)
                }
            )
        )
    }

    /// A legacy `shortcuts.json` that still parses, offered as an import when
    /// the active profile has no data file of its own.
    private func resumableLegacyMirror(
        layout: ShortcutProfileLayout,
        activeProfileID: UUID
    ) -> ForeignMirror? {
        guard
            let data = try? Data(contentsOf: layout.mirrorURL),
            let shortcuts = try? JSONDecoder().decode([AppShortcut].self, from: data),
            Set(shortcuts.map(\.id)).count == shortcuts.count
        else {
            return nil
        }
        log("PROFILE_TRACE_MIGRATION_RESUMABLE id=\(activeProfileID.uuidString) shortcuts=\(shortcuts.count)")
        return ForeignMirror(profileID: activeProfileID, shortcuts: shortcuts, rawBytes: data)
    }

    // MARK: - Migration

    private func migrate(layout: ShortcutProfileLayout) -> LoadState {
        let now = dateProvider()
        let profileID = idProvider()
        let profile = ShortcutProfile(
            id: profileID,
            name: String(localized: "Default", bundle: WinkResourceBundle.bundle),
            createdAt: now
        )

        var migrated: [AppShortcut] = []
        /// The exact bytes to install as the Default profile's data file. A
        /// re-encoding would drop any JSON member `AppShortcut` does not
        /// model, which is precisely what D4 promises to preserve — so the
        /// migration copies rather than round trips, and only synthesizes
        /// bytes for the fresh-install case where there is no source.
        var migratedBytes: Data?
        var legacySourceUnreadable = false
        var legacyMigrationFailure: LegacyMigrationFailure?

        if fileManager.fileExists(atPath: layout.mirrorURL.path) {
            do {
                // One read. `migrated` arms the runtime and `migratedBytes`
                // becomes the profile file, so they must be the same bytes:
                // reading the path twice can observe two different files, and
                // a failed second read used to fall through to a re-encode
                // that drops the members this copy exists to preserve.
                let legacy = try profilePersistenceService(for: layout.mirrorURL).loadWithBytes()
                migrated = legacy.shortcuts
                migratedBytes = legacy.data
            } catch {
                // The existing quarantine already ran and preserved a copy.
                // An empty Default profile must not then mirror itself over a
                // file that still holds the user's (possibly hand-repairable)
                // data, so the mirror write is skipped below.
                legacySourceUnreadable = true
                legacyMigrationFailure = LegacyMigrationFailure(
                    preservedCopyPath: preservedCopyPath(from: error)
                )
                log("PROFILE_TRACE_MIGRATION_SOURCE_UNREADABLE reason=\(error.localizedDescription)")
            }
        }

        // The failure travels IN the committed manifest, not just in the
        // returned load state: this commit is what makes every later launch
        // skip migrate(), so it must also carry the evidence that migration
        // did not actually recover anything — otherwise a relaunch presents
        // the vanished configuration as an ordinary empty install.
        let migratedManifest = ShortcutProfileManifest(
            profiles: [profile],
            legacyMigrationFailure: legacyMigrationFailure.map {
                ShortcutProfileManifest.LegacyMigrationFailureRecord(preservedCopyPath: $0.preservedCopyPath)
            }
        )
        do {
            if let migratedBytes {
                try writeProfileBytes(migratedBytes, profileID: profileID, layout: layout)
            } else {
                try writeProfileData(migrated, profileID: profileID, layout: layout)
            }
            try commitManifest(migratedManifest, layout: layout)
            try commitActivePointer(profileID, layout: layout)
        } catch {
            manifest = nil
            locator.setActiveProfileID(nil)
            log("PROFILE_TRACE_MIGRATION_FAILED reason=\(error.localizedDescription)")
            return .storageUnavailable
        }

        manifest = migratedManifest
        pointedProfileID = profileID
        locator.setActiveProfileID(profileID)

        // When the legacy source was unreadable the mirror is deliberately
        // NOT rewritten — it holds the user's unrecovered bytes, and the
        // migration-failure banner is that state's surface, not the caveat.
        var migrationMirrorStale = false
        if !legacySourceUnreadable {
            migrationMirrorStale = !writeMirrorForActiveProfile(bytes: migratedBytes, profileID: profileID, layout: layout)
        }

        log("PROFILE_TRACE_MIGRATED shortcuts=\(migrated.count) source=\(layout.mirrorURL.path)")

        return .ready(
            LoadedProfiles(
                profiles: [profile],
                activeProfileID: profileID,
                activeShortcuts: migrated,
                unreadableProfileIDs: [],
                orphanProfileIDs: orphanProfileIDs(layout: layout, manifest: ShortcutProfileManifest(profiles: [profile])),
                duplicateShortcutIDs: [],
                foreignMirror: nil,
                compatMirrorStale: migrationMirrorStale,
                legacyMigrationFailure: legacyMigrationFailure
            )
        )
    }

    // MARK: - Integrity

    private struct IntegrityReport {
        var unreadable: Set<UUID> = []
        var orphans: Set<UUID> = []
        var duplicateShortcutIDs: Set<UUID> = []
    }

    /// Reads every profile's data file. At most `maximumProfileCount` small
    /// JSON files, so this stays in the sub-millisecond range at launch while
    /// letting the UI mark unreadable profiles before the user tries to
    /// activate one.
    private func scanIntegrity(
        layout: ShortcutProfileLayout,
        manifest: ShortcutProfileManifest,
        activeProfileID: UUID,
        activeShortcuts: [AppShortcut]
    ) -> IntegrityReport {
        var report = IntegrityReport()
        var seenShortcutIDs: [UUID: UUID] = [:]

        for shortcut in activeShortcuts {
            seenShortcutIDs[shortcut.id] = activeProfileID
        }

        for profile in manifest.profiles where profile.id != activeProfileID {
            guard let shortcuts = decodeProfileLeniently(profile.id, layout: layout) else {
                report.unreadable.insert(profile.id)
                log("PROFILE_TRACE_UNREADABLE id=\(profile.id.uuidString) reason=inactive_decode_failed preservedCopyPath=none")
                continue
            }
            // WITHIN-profile uniqueness is the strict loader's rule, so the
            // scan applies it too: a lenient decode that tolerates duplicate
            // rows would leave the profile out of the unreadable set, every
            // picker would enable it, and activation would refuse the same
            // file forever — a permanently selectable row that fails on
            // every attempt.
            guard Set(shortcuts.map(\.id)).count == shortcuts.count else {
                report.unreadable.insert(profile.id)
                log("PROFILE_TRACE_UNREADABLE id=\(profile.id.uuidString) reason=duplicate_shortcut_id preservedCopyPath=none")
                continue
            }

            for shortcut in shortcuts {
                if let owner = seenShortcutIDs[shortcut.id], owner != profile.id {
                    report.duplicateShortcutIDs.insert(shortcut.id)
                    log("PROFILE_TRACE_DUPLICATE_ID id=\(shortcut.id.uuidString) profiles=\(owner.uuidString),\(profile.id.uuidString)")
                } else {
                    seenShortcutIDs[shortcut.id] = profile.id
                }
            }
        }

        report.orphans = orphanProfileIDs(layout: layout, manifest: manifest)
        for orphan in report.orphans.sorted(by: { $0.uuidString < $1.uuidString }) {
            log("PROFILE_TRACE_ORPHAN id=\(orphan.uuidString)")
        }

        return report
    }

    private func orphanProfileIDs(
        layout: ShortcutProfileLayout,
        manifest: ShortcutProfileManifest
    ) -> Set<UUID> {
        let known = Set(manifest.profiles.map(\.id))
        let names = (try? fileManager.contentsOfDirectory(atPath: layout.profilesDirectory.path)) ?? []
        return Set(
            names
                .compactMap(ShortcutProfileLayout.profileID(forDataFileName:))
                .filter { !known.contains($0) }
        )
    }

    /// Decodes an inactive profile without quarantining it: nothing is about
    /// to overwrite that file, so preserving a copy would only scatter
    /// `.load-failure-` files for data nobody touched. Quarantine happens if
    /// and when the user tries to activate it.
    private func decodeProfileLeniently(_ profileID: UUID, layout: ShortcutProfileLayout) -> [AppShortcut]? {
        guard
            let data = try? Data(contentsOf: layout.profileDataURL(profileID)),
            let shortcuts = try? JSONDecoder().decode([AppShortcut].self, from: data)
        else {
            return nil
        }
        return shortcuts
    }

    // MARK: - Mirror

    /// Classifies `shortcuts.json` against two independent questions, in this
    /// order:
    ///
    /// 1. **Is it current?** — its bytes equal the live active profile's bytes.
    ///    This is the only test that can answer that, because the descriptor
    ///    describes the mirror, not the profile: after *any* crash between a
    ///    data-file write and the mirror write — an ordinary save to the same
    ///    profile included — the mirror and its descriptor still agree with
    ///    each other while the profile has moved on.
    /// 2. **Did Wink write it?** — its digest equals the descriptor's. This is
    ///    what separates a mirror this build left behind from one another
    ///    build rewrote.
    ///
    /// Current wins outright. Not-current-but-ours is stale and is repaired
    /// silently. Not-current-and-not-ours is a foreign edit and always asks.
    /// Not-current with no usable descriptor is of unknown provenance and is
    /// left strictly alone: migration deliberately skips the mirror write when
    /// the legacy file was unreadable, and rewriting it there would destroy
    /// bytes the user may still be able to repair by hand.
    /// `mirrorHealthy` is false when a startup repair was owed and refused
    /// (a missing compat file that could not be written, an unreadable one,
    /// a stale one whose repair failed or deferred, or a current one whose
    /// stale descriptor could not be corrected): startup stays
    /// `.ready` — the mirror is derived data — but the caller surfaces the
    /// same caveat every other mirror-rewriting path reports.
    private func detectForeignMirror(
        layout: ShortcutProfileLayout,
        activeProfileID: UUID,
        activeBytes: Data
    ) -> (offer: ForeignMirror?, mirrorHealthy: Bool) {
        guard let mirrorData = try? Data(contentsOf: layout.mirrorURL) else {
            guard !fileManager.fileExists(atPath: layout.mirrorURL.path) else {
                // Present but unreadable. Its bytes cannot be classified and
                // cannot be copied, so the one thing that must not happen is
                // an overwrite — and the directory can still permit one.
                // `writeMirror` refuses this on its own; stopping here as well
                // keeps the trace honest instead of logging a repair that was
                // never attempted.
                log("PROFILE_TRACE_MIRROR_UNREADABLE active=\(activeProfileID.uuidString)")
                return (nil, false)
            }
            // Nothing on disk to lose — but a refused write leaves the E2E
            // harness and downgraded builds with NO configuration at all.
            return (nil, writeMirrorForActiveProfile(bytes: activeBytes, profileID: activeProfileID, layout: layout))
        }

        let descriptor = loadMirrorDescriptor(layout: layout)
        let mirrorDigest = Self.digest(mirrorData)

        // Raw file bytes on BOTH sides. A profile file can legitimately carry
        // JSON members `AppShortcut` does not model — a newer build wrote it,
        // or a user hand-edited it — and those members survive the file but
        // not a decode/re-encode round trip. Comparing against a re-encoding
        // would report a mismatch for a mirror that is already a perfect byte
        // copy, and the repair that followed would strip the preserved members
        // from the very file a downgrade reads.
        if mirrorDigest == Self.digest(activeBytes) {
            // Current. Keep the descriptor honest so a later comparison
            // attributes correctly; the mirror bytes themselves are already
            // right, so this rewrite is a no-op on content.
            if descriptor?.profileID != activeProfileID || descriptor?.sha256 != mirrorDigest {
                guard writeMirrorForActiveProfile(bytes: activeBytes, profileID: activeProfileID, layout: layout) else {
                    // The bytes are usable, but a stale descriptor that could
                    // not be corrected must not stay authoritative: after a
                    // partial A→B switch it still names A, and if an older
                    // build later edits the mirror, the next launch would
                    // attribute that edit to A and offer to import B-derived
                    // changes into the wrong profile. A decoded descriptor is
                    // this lineage's own metadata, so dropping it is safe and
                    // demotes the file to unknown provenance — which asks
                    // nothing and preserves everything. An UNDECODABLE one may
                    // be a newer build's; it cannot vouch for anything here,
                    // so it is left for that build to find. Either way the
                    // owed repair was refused, and that reports the same
                    // caveat as every other refused mirror write.
                    if descriptor != nil {
                        try? fileManager.removeItem(at: layout.mirrorDescriptorURL)
                    }
                    log("PROFILE_TRACE_MIRROR_DESCRIPTOR_REPAIR_FAILED describedProfile=\(descriptor?.profileID.uuidString ?? "none") active=\(activeProfileID.uuidString)")
                    return (nil, false)
                }
            }
            return (nil, true)
        }

        guard let descriptor else {
            // "Leave it alone" only protects these bytes until the next
            // ordinary save rewrites the mirror. Unlike the quarantine paths,
            // nothing here preserved a copy first, so an older build's edits
            // could be lost with no trace. Copy them beside the original now,
            // which makes every later overwrite non-destructive.
            preserveUnknownMirror(mirrorData, digest: mirrorDigest, descriptor: nil, layout: layout)
            log("PROFILE_TRACE_MIRROR_UNKNOWN active=\(activeProfileID.uuidString) reason=no_descriptor")
            // Deliberately left in place — but for the harness and a
            // downgraded build the file still does not reflect the active
            // profile, which is exactly what the caveat tells the user.
            return (nil, false)
        }

        // Only the CURRENT digest counts as "Wink wrote this". Remembering the
        // previous one would also match a user or older build deliberately
        // restoring the immediately preceding configuration — byte-identical
        // on disk to the crash window it was meant to recognize — and this
        // branch overwrites silently. When two states cannot be told apart,
        // the safe wrong answer is to ask, not to act.
        if descriptor.sha256 == mirrorDigest {
            // Byte equality proves only that these bytes are ones Wink wrote,
            // not that Wink was the last to write them: an older build or a
            // tool restoring the exact previous payload lands here too, and
            // that state is indistinguishable on disk from the crash window.
            // The repair therefore obeys the same rule as every other
            // overwrite — preserve a copy first — so both readings are safe
            // and the crash case still needs no banner.
            // This copy is the ONLY thing that makes the repair below safe.
            // When the descriptor names the active profile, `writeMirror` sees
            // its own current payload and skips its preservation guard by
            // design — so a silently failed copy here would leave the overwrite
            // completely unguarded, which is the one path the whole rule exists
            // to close. A failed copy therefore defers the repair; the mirror
            // stays stale, the next save re-attempts, and nothing is lost.
            guard preserveUnknownMirror(
                mirrorData,
                digest: mirrorDigest,
                descriptor: descriptor,
                layout: layout
            ) else {
                log("PROFILE_TRACE_MIRROR_STALE_REPAIR_DEFERRED describedProfile=\(descriptor.profileID.uuidString)")
                return (nil, false)
            }
            log("PROFILE_TRACE_MIRROR_STALE describedProfile=\(descriptor.profileID.uuidString) active=\(activeProfileID.uuidString)")
            return (nil, writeMirrorForActiveProfile(bytes: activeBytes, profileID: activeProfileID, layout: layout))
        }

        // A descriptor naming a profile that no longer exists cannot support
        // the import side of the banner, and recreating that profile would
        // resurrect exactly what D9 refuses to adopt. Unknown provenance:
        // leave both files alone.
        guard manifest?.profile(id: descriptor.profileID) != nil else {
            preserveUnknownMirror(mirrorData, digest: mirrorDigest, descriptor: descriptor, layout: layout)
            log("PROFILE_TRACE_MIRROR_UNKNOWN active=\(activeProfileID.uuidString) reason=descriptor_profile_deleted")
            // Same reading as the no-descriptor branch above.
            return (nil, false)
        }

        log("PROFILE_TRACE_FOREIGN_MIRROR profile=\(descriptor.profileID.uuidString)")
        return (Self.foreignMirrorOffer(profileID: descriptor.profileID, bytes: mirrorData), true)
    }

    /// The ONE construction rule for an importable offer: shortcuts are
    /// attached only when the bytes decode with unique ids. A payload with
    /// duplicate shortcut IDs is not importable — writing it would publish
    /// duplicate rows into the runtime and leave a file the strict loader
    /// quarantines on the next launch, arming nothing — so those bytes carry
    /// no decoded side and the UI offers only keep-and-overwrite.
    private static func foreignMirrorOffer(profileID: UUID, bytes: Data) -> ForeignMirror {
        let decoded = (try? JSONDecoder().decode([AppShortcut].self, from: bytes))
            .flatMap { Set($0.map(\.id)).count == $0.count ? $0 : nil }
        return ForeignMirror(profileID: profileID, shortcuts: decoded, rawBytes: bytes)
    }

    /// Rebuilds a pending offer from the file as it is NOW, after
    /// `adoptForeignMirror` refused a stale one — by re-running the FULL
    /// startup classification, not by attaching the new bytes to the stale
    /// offer's target. The distinction is load-bearing: after a partial
    /// inactive-profile import (profile data written, the active profile's
    /// bytes restored to the mirror, only the descriptor write failed), the
    /// file now holds the ACTIVE profile's payload. A refresh that kept the
    /// old inactive target would offer to "import" the active profile's
    /// bytes into it — and a retry would overwrite that profile's data with
    /// the wrong payload. Classification recognizes the bytes as current,
    /// repairs the descriptor, and dissolves the offer instead. Its other
    /// side effects (preserve-before-overwrite, stale repair) are the same
    /// startup semantics a relaunch would apply.
    ///
    /// In the interrupted-migration recovery there is no active profile to
    /// classify against; the offer is rebuilt by the same constructor that
    /// flow used originally, keeping its target.
    /// Rewrites the compat mirror from the ACTIVE profile's strict payload.
    /// For flows that invalidate a foreign offer without an import — deleting
    /// the profile the offer targeted — so the file the E2E harness and a
    /// downgraded build read does not keep describing a profile that no
    /// longer exists. Best-effort by contract: the caller's operation has
    /// already committed and cannot be blocked on mirror hygiene; a refusal
    /// is traced by the write path and startup classifies the leftover as
    /// unknown provenance.
    @discardableResult
    func restoreMirrorToActiveProfile() -> Bool {
        guard let layout, let activeProfileID = locator.currentActiveProfileID() else { return false }
        return writeMirrorForActiveProfile(profileID: activeProfileID, layout: layout)
    }

    func refreshedForeignMirrorOffer(replacing stale: ForeignMirror) -> ForeignMirror? {
        guard let layout else { return nil }
        log("PROFILE_TRACE_FOREIGN_MIRROR_REFRESHED profile=\(stale.profileID.uuidString)")
        guard let activeProfileID = locator.currentActiveProfileID() else {
            return resumableLegacyMirror(layout: layout, activeProfileID: stale.profileID)
        }
        // The STRICT payload, not a raw read: startup runs the strict loader
        // on the active profile before detection ever sees its bytes, and a
        // profile that fails it is quarantined, never classified against.
        // Classifying against raw bytes here would let a malformed canonical
        // file drive the stale-repair branch and overwrite a usable compat
        // copy with the malformed payload — a write startup would never make.
        guard let payload = try? profilePayload(in: activeProfileID) else {
            // Classification UNAVAILABLE is not "nothing foreign remains":
            // dissolving here would silently drop a still-valid outside edit
            // because the canonical file went bad — the one moment that edit
            // may be the user's best copy. Rebuild a same-target offer from
            // the file as it is (construction only, nothing written; the
            // adoption gates re-check everything, and cross-profile
            // ownership fails closed while a sibling is unreadable). A
            // vanished file has nothing left to offer.
            guard let bytes = try? Data(contentsOf: layout.mirrorURL) else { return nil }
            return Self.foreignMirrorOffer(profileID: stale.profileID, bytes: bytes)
        }
        return detectForeignMirror(
            layout: layout,
            activeProfileID: activeProfileID,
            activeBytes: payload.bytes
        ).offer
    }

    /// Copies a `shortcuts.json` Wink cannot attribute, so a later save can
    /// overwrite the mirror without destroying whatever wrote it. Named by
    /// content digest: relaunching with the same unattributable bytes rewrites
    /// the same path with identical content instead of accumulating copies.
    /// True when the mirror bytes also live, byte for byte, in the profile
    /// data file the descriptor names — the state every ordinary A→B switch is
    /// in, because the mirror still holds A while B is being written. Copying
    /// those to `shortcuts.unknown-*.json` protects nothing (A's file is the
    /// copy) and leaves one junk file per distinct payload ever mirrored.
    ///
    /// The proof is byte equality with a file that exists right now, so it does
    /// not depend on the manifest being readable. The only path that removes
    /// the source afterwards is the user explicitly deleting that profile,
    /// which is a deliberate discard of exactly those bytes.
    /// Whether `url` exists and holds exactly `expected`.
    nonisolated private static func fileHolds(_ expected: Data, at url: URL) -> Bool {
        // lstat semantics first: a candidate that is a symbolic link can
        // "hold" the right bytes only by resolving THROUGH to the mirror
        // itself, and the authorization this check feeds is "an INDEPENDENT
        // copy exists" — an alias is the opposite. Requiring a regular file
        // is the property that matters: atomic-rename replacement keeps a
        // hard link safe (the old inode keeps the old bytes), while a
        // symlink, FIFO, or anything else never counts as a copy.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return false }
        guard let current = try? Data(contentsOf: url) else { return false }
        return digest(current) == digest(expected)
    }

    /// Puts `data` beside the compat file, verified and flushed, and returns
    /// whether a copy provably exists afterwards. `false` means no caller may
    /// overwrite these bytes.
    ///
    /// This is deliberately the ONLY implementation. The rule had been written
    /// twice — once here and once at the mirror writer — and the second copy
    /// kept the naive "a file exists at that path, so a copy exists" check
    /// through a round that fixed the first. A filename is not the property
    /// that matters; contents are.
    ///
    /// Candidate names, most preferred first: the 12-character digest prefix,
    /// then the full digest as the unambiguous fallback for when the prefix
    /// name is occupied by other bytes after a partial restore or a manual
    /// edit. Those occupying bytes are not ours to overwrite either, so when
    /// no name is usable this refuses rather than choosing a victim.
    nonisolated private static func preserveBytes(
        _ data: Data,
        digest dataDigest: String,
        layout: ShortcutProfileLayout,
        writeClient: WriteClient,
        diagnosticClient: DiagnosticClient
    ) -> Bool {
        let candidates = [
            layout.appDirectory.appendingPathComponent("shortcuts.unknown-\(dataDigest.prefix(12)).json"),
            layout.appDirectory.appendingPathComponent("shortcuts.unknown-\(dataDigest).json"),
        ]
        for candidate in candidates {
            if fileHolds(data, at: candidate) {
                // Byte equality proves CONTENT, not durability: a durable
                // write that failed at its flush stage — this launch's,
                // caught below, or a previous launch's — leaves a file whose
                // rename may not be on stable storage. A copy AUTHORIZES an
                // overwrite, so the barrier runs again before an existing
                // candidate is accepted; re-flushing an already-flushed file
                // is a cheap no-op on a healthy volume, and a volume that
                // cannot flush must not authorize anything.
                do {
                    try WriteClient.flushToStableStorage(candidate)
                    return true
                } catch {
                    let message = "PROFILE_TRACE_MIRROR_UNKNOWN_PRESERVE_FAILED reason=reflush_failed"
                    logger.error("\(message, privacy: .public)")
                    diagnosticClient.log(message)
                    return false
                }
            }
            guard !FileManager.default.fileExists(atPath: candidate.path) else { continue }
            do {
                try writeClient.writeDurable(data, candidate)
                diagnosticClient.log("PROFILE_TRACE_MIRROR_UNKNOWN_PRESERVED path=\(candidate.path)")
                return true
            } catch {
                let message = "PROFILE_TRACE_MIRROR_UNKNOWN_PRESERVE_FAILED reason=\(error.localizedDescription)"
                logger.error("\(message, privacy: .public)")
                diagnosticClient.log(message)
                // A failed durable write must not leave a byte-identical
                // candidate behind for the next attempt to find, trust, and
                // authorize an overwrite with.
                try? FileManager.default.removeItem(at: candidate)
                return false
            }
        }
        let message = "PROFILE_TRACE_MIRROR_WRITE_SKIPPED reason=no_usable_preservation_path"
        logger.error("\(message, privacy: .public)")
        diagnosticClient.log(message)
        return false
    }

    nonisolated private static func mirrorIsHeldByItsSourceProfile(
        _ mirrorData: Data,
        digest mirrorDigest: String,
        descriptor: ShortcutProfileMirrorDescriptor?,
        layout: ShortcutProfileLayout
    ) -> Bool {
        // A descriptor that does not claim these bytes cannot vouch for where
        // they came from, so it cannot license skipping the copy either.
        guard let descriptor, descriptor.sha256 == mirrorDigest else { return false }
        // Through `fileHolds`, not a bare read: this exemption asserts that
        // an INDEPENDENT copy of the mirror bytes exists in the source
        // profile's file, and a `Profiles/<id>.json` that is a symbolic link
        // to shortcuts.json "holds" them only by resolving through to the
        // very file the skipped preservation would let the next switch
        // replace — losing the bytes and corrupting the source profile in
        // one write. Same rule as the candidate check: regular file or it
        // does not count, and otherwise these bytes are the last copy.
        return fileHolds(mirrorData, at: layout.profileDataURL(descriptor.profileID))
    }

    /// Every profile carries a name the create and rename paths would accept.
    /// Asked as one question so a rule added to `ShortcutProfileNameRules` is
    /// enforced on load for free, rather than drifting into a state only a
    /// hand-edited or restored file can reach.
    nonisolated private static func everyNameIsAddressable(_ profiles: [ShortcutProfile]) -> Bool {
        profiles.allSatisfy {
            // `excluding` is the profile itself, which must not count as its
            // own collision.
            ShortcutProfileNameRules.violation(for: $0.name, excluding: $0.id, in: profiles) == nil
        }
    }

    /// Returns whether a copy of `data` is now on disk — including the cases
    /// where none was needed, because the bytes are already held elsewhere or
    /// a copy of them already exists. Only a failed write returns false, and a
    /// caller that is about to overwrite these bytes must not proceed on it.
    /// Returns whether a copy of `data` is now on disk — including the cases
    /// where none was needed, because the bytes are already held by their
    /// source profile. Only a genuine failure returns false, and a caller
    /// about to overwrite these bytes must not proceed on it.
    @discardableResult
    private func preserveUnknownMirror(
        _ data: Data,
        digest: String,
        descriptor: ShortcutProfileMirrorDescriptor?,
        layout: ShortcutProfileLayout
    ) -> Bool {
        guard !Self.mirrorIsHeldByItsSourceProfile(
            data,
            digest: digest,
            descriptor: descriptor,
            layout: layout
        ) else { return true }
        return Self.preserveBytes(
            data,
            digest: digest,
            layout: layout,
            writeClient: writeClient,
            diagnosticClient: diagnosticClient
        )
    }

    private func loadMirrorDescriptor(layout: ShortcutProfileLayout) -> ShortcutProfileMirrorDescriptor? {
        guard
            let data = try? Data(contentsOf: layout.mirrorDescriptorURL),
            let descriptor = try? Self.metadataDecoder.decode(ShortcutProfileMirrorDescriptor.self, from: data),
            descriptor.schemaVersion == ShortcutProfileMirrorDescriptor.currentSchemaVersion
        else {
            return nil
        }
        return descriptor
    }

    @discardableResult
    private func writeMirrorForActiveProfile(
        bytes: Data? = nil,
        profileID: UUID,
        layout: ShortcutProfileLayout
    ) -> Bool {
        let data: Data
        if let bytes {
            data = bytes
        } else if let payload = try? profilePayload(in: profileID) {
            // STRICT, not a raw read: this arm serves "keep this profile"
            // and the post-import restore, and copying a canonical file that
            // has gone malformed (or grown duplicate ids) into the mirror
            // would report success while the next launch quarantines the
            // profile and arms nothing — with the only good copy tucked in
            // an unadvertised preservation file. Refusing keeps the caller's
            // failure path honest instead.
            data = payload.bytes
        } else {
            log("PROFILE_TRACE_MIRROR_FAILED reason=profile_unreadable")
            return false
        }
        return Self.writeMirror(
            data: data,
            profileID: profileID,
            layout: layout,
            writeClient: writeClient,
            diagnosticClient: diagnosticClient
        )
    }

    /// `static` and parameterized so the `@Sendable` derived-copy closure can
    /// call it without capturing the main-actor-isolated store.
    @discardableResult
    nonisolated private static func writeMirror(
        data: Data,
        profileID: UUID,
        layout: ShortcutProfileLayout,
        writeClient: WriteClient,
        diagnosticClient: DiagnosticClient
    ) -> Bool {
        // Preserve anything unattributable BEFORE replacing it. Doing this
        // here rather than at each call site is what makes the invariant
        // unconditional: the launch-time classification cannot see an edit
        // made while Wink is running, so every overwrite has to re-check.
        // Reading and hashing a few kilobytes on a user-initiated save is not
        // a cost worth trading a silent data loss for.
        do {
            // Bounded loop, not a single pass: `preserveBytes` ends in a
            // durable flush that is slow enough to be a real window, and an
            // older build or external tool that rewrites the mirror inside
            // it would otherwise have its NEW payload replaced without ever
            // being inspected or preserved — only the earlier bytes were
            // copied. After preserving, the mirror is re-read; changed bytes
            // re-enter classification, and a file that keeps changing under
            // the write is refused rather than raced.
            var guardAttempts = 0
            while true {
            guardAttempts += 1
            guard guardAttempts <= 3 else {
                let message = "PROFILE_TRACE_MIRROR_WRITE_SKIPPED reason=mirror_kept_changing"
                logger.error("\(message, privacy: .public)")
                diagnosticClient.log(message)
                return false
            }
            // Absence is re-tested on EVERY pass, never decided once up
            // front: a mirror an older build or external tool creates
            // between an absence check and the replacement below would
            // otherwise skip this loop entirely and be destroyed unread. A
            // file that appears re-enters classification as what it now is,
            // and the residual window shrinks to the same final-comparison
            // width the always-present case has.
            guard FileManager.default.fileExists(atPath: layout.mirrorURL.path) else {
                break
            }
            // Present but unreadable is the case this guard exists for: the
            // directory can still accept an atomic replacement, so treating an
            // unreadable file as absent would destroy the only copy of an
            // older build's or an external tool's edits. Nothing may overwrite
            // bytes it could not first capture.
            guard let existing = try? Data(contentsOf: layout.mirrorURL) else {
                let message = "PROFILE_TRACE_MIRROR_WRITE_SKIPPED reason=existing_unreadable"
                logger.error("\(message, privacy: .public)")
                diagnosticClient.log(message)
                return false
            }
            let existingDigest = digest(existing)
            // Schema-validated, exactly as the startup read is. Without this
            // a descriptor written by a NEWER build would be decoded on its
            // v1 fields and could authorize overwriting that build's mirror —
            // the one payload most likely to carry members this build cannot
            // model.
            let descriptor = (try? Data(contentsOf: layout.mirrorDescriptorURL))
                .flatMap { try? metadataDecoder.decode(ShortcutProfileMirrorDescriptor.self, from: $0) }
                .flatMap { $0.schemaVersion == ShortcutProfileMirrorDescriptor.currentSchemaVersion ? $0 : nil }
            // Ours, and for the profile being written: Wink's own previous
            // output, which this write supersedes. Preserving that would mean
            // a copy on every save, which is unbounded garbage rather than
            // protection.
            //
            // Ours but for a DIFFERENT profile: a switch whose mirror write
            // never landed, so these bytes are another profile's and the
            // descriptor cannot vouch for them being superseded here.
            let isWinkOwnCurrentPayload = descriptor?.sha256 == existingDigest
                && descriptor?.profileID == profileID
            // Ours, for a different profile, and that profile STILL holds these
            // exact bytes: an ordinary A→B switch. There is nothing to lose, so
            // copying here would only accumulate junk beside the real files.
            let isHeldByItsSourceProfile = mirrorIsHeldByItsSourceProfile(
                existing,
                digest: existingDigest,
                descriptor: descriptor,
                layout: layout
            )
            if !isWinkOwnCurrentPayload, !isHeldByItsSourceProfile, existingDigest != digest(data) {
                // A file at the expected path is not proof of a copy. The name
                // carries only a digest PREFIX, and a partial restore, a manual
                // edit, or corruption can leave something else there — at which
                // point treating it as the copy would authorize destroying the
                // last real one. Verify the contents, and when they disagree
                // fall back to the full-digest name rather than overwriting a
                // file whose value is unknown.
                guard Self.preserveBytes(
                    existing,
                    digest: existingDigest,
                    layout: layout,
                    writeClient: writeClient,
                    diagnosticClient: diagnosticClient
                ) else {
                    // "Preserve before overwriting" is not advice, it is the
                    // condition under which overwriting is allowed. A full
                    // volume can refuse the copy of a large edited payload and
                    // still accept the smaller incoming write, which would
                    // destroy the only copy of that edit.
                    return false
                }
            }
            // Immediately before the replacement: bytes that moved during
            // the preservation re-enter the loop and are classified and
            // preserved as what they now are. The residual window shrinks
            // to the digest comparison itself.
            if let recheck = try? Data(contentsOf: layout.mirrorURL), digest(recheck) == existingDigest {
                break
            }
            continue
            }
        }

        // The mirror is derived data written last. Its failure is reported but
        // never fails the operation that produced it, because a stale mirror
        // cannot affect this build's behavior.
        do {
            try writeClient.write(data, layout.mirrorURL)
        } catch {
            let message = "PROFILE_TRACE_MIRROR_FAILED reason=mirror_write_failed detail=\(error.localizedDescription)"
            logger.error("\(message, privacy: .public)")
            diagnosticClient.log(message)
            return false
        }

        let descriptor = ShortcutProfileMirrorDescriptor(
            profileID: profileID,
            sha256: digest(data)
        )
        do {
            try writeClient.write(try metadataEncoder.encode(descriptor), layout.mirrorDescriptorURL)
        } catch {
            // The bytes just written are the new truth, but the OLD
            // descriptor still describes whatever was here before — after an
            // A→B switch it still names A, and if an older build edits this
            // mirror before the next launch repairs the pairing, startup
            // would trust it and offer the edit for import into the wrong
            // profile. Same rule as the startup repair: a descriptor that
            // decodes at the current schema is this lineage's own metadata,
            // so dropping it is safe and demotes the file to unknown
            // provenance — which asks nothing and preserves everything. An
            // undecodable one may be a newer build's and is left alone.
            let prior = (try? Data(contentsOf: layout.mirrorDescriptorURL))
                .flatMap { try? metadataDecoder.decode(ShortcutProfileMirrorDescriptor.self, from: $0) }
            if prior?.schemaVersion == ShortcutProfileMirrorDescriptor.currentSchemaVersion {
                try? FileManager.default.removeItem(at: layout.mirrorDescriptorURL)
            }
            let message = "PROFILE_TRACE_MIRROR_FAILED reason=descriptor_write_failed detail=\(error.localizedDescription)"
            logger.error("\(message, privacy: .public)")
            diagnosticClient.log(message)
            return false
        }

        return true
    }

    nonisolated static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Writes

    /// Metadata files only. Shortcut payloads go through
    /// `PersistenceService.encodeShortcuts` so the canonical file and its
    /// mirror are byte-identical by construction.
    nonisolated private static var metadataEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    nonisolated private static var metadataDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func profilePersistenceService(for url: URL) -> PersistenceService {
        PersistenceService(
            storageURLProvider: { url },
            diagnosticClient: PersistenceService.DiagnosticClient(log: diagnosticClient.log),
            backupIDProvider: backupIDProvider
        )
    }

    private func writeProfileData(
        _ shortcuts: [AppShortcut],
        profileID: UUID,
        layout: ShortcutProfileLayout
    ) throws {
        try writeProfileBytes(
            try PersistenceService.encodeShortcuts(shortcuts),
            profileID: profileID,
            layout: layout
        )
    }

    /// Writes an already-encoded payload verbatim, so a caller that has real
    /// source bytes can preserve members the model does not carry.
    private func writeProfileBytes(
        _ data: Data,
        profileID: UUID,
        layout: ShortcutProfileLayout
    ) throws {
        let url = layout.profileDataURL(profileID)
        do {
            try writeClient.write(data, url)
        } catch {
            throw StoreError.writeFailed(path: url.path, reason: error.localizedDescription)
        }
    }

    private func commitManifest(_ updated: ShortcutProfileManifest, layout: ShortcutProfileLayout) throws {
        do {
            try writeClient.write(try Self.metadataEncoder.encode(updated), layout.manifestURL)
        } catch {
            throw StoreError.writeFailed(path: layout.manifestURL.path, reason: error.localizedDescription)
        }
    }

    private func commitActivePointer(_ profileID: UUID, layout: ShortcutProfileLayout) throws {
        let pointer = ShortcutProfileActivePointer(activeProfileID: profileID)
        do {
            try writeClient.write(try Self.metadataEncoder.encode(pointer), layout.activePointerURL)
        } catch {
            throw StoreError.writeFailed(path: layout.activePointerURL.path, reason: error.localizedDescription)
        }
    }

    // MARK: - Reads

    /// Strict read of any profile, quarantining on failure. Used when the user
    /// is about to activate or duplicate a profile — the moment its contents
    /// stop being merely displayed and start being relied on.
    /// A profile's decoded rows together with the exact bytes they were
    /// decoded from. The two travel as one value because every consumer that
    /// applies a payload also has to write it, and reading the file a second
    /// time to get the bytes reintroduces the gap this type exists to close.
    struct ValidatedProfilePayload: Sendable {
        let shortcuts: [AppShortcut]
        let bytes: Data
    }

    func profilePayload(in profileID: UUID) throws -> ValidatedProfilePayload {
        guard let layout else { throw StoreError.storageUnavailable }
        guard manifest?.profile(id: profileID) != nil else {
            throw StoreError.profileNotFound(profileID)
        }
        // `PersistenceService.load()` returns [] for a file that does not
        // exist — correct for a first launch, wrong here. Without this check
        // a missing profile reads as an empty one, and "validate before
        // commit" would happily commit a pointer to a profile that is gone.
        guard fileManager.fileExists(atPath: layout.profileDataURL(profileID).path) else {
            throw StoreError.profileUnreadable(id: profileID, reason: "data file is missing")
        }
        do {
            let loaded = try profilePersistenceService(for: layout.profileDataURL(profileID)).loadWithBytes()
            guard let bytes = loaded.data else {
                throw StoreError.profileUnreadable(id: profileID, reason: "data file is missing")
            }
            return ValidatedProfilePayload(shortcuts: loaded.shortcuts, bytes: bytes)
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.profileUnreadable(id: profileID, reason: error.localizedDescription)
        }
    }

    func shortcuts(in profileID: UUID) throws -> [AppShortcut] {
        try profilePayload(in: profileID).shortcuts
    }


    /// What other profiles are known to hold. `isComplete` is false when some
    /// sibling profile could not be read, which makes every ownership question
    /// unanswerable rather than answered "no".
    struct ShortcutOwnership: Equatable, Sendable {
        var idsHeldElsewhere: Set<UUID>
        var isComplete: Bool

        /// Fail-closed. An unreadable sibling could be holding this ID, and
        /// wrongly deleting another profile's Insights history is not
        /// recoverable, while wrongly keeping it costs nothing but a stale row.
        func isRetainedElsewhere(_ id: UUID) -> Bool {
            !isComplete || idsHeldElsewhere.contains(id)
        }
    }

    /// Shortcut IDs some profile other than `profileID` also holds. Every
    /// usage-deletion path consults this, so removing a shortcut can never
    /// erase history belonging to one that still exists elsewhere — including
    /// the cross-profile duplicates `scanIntegrity` deliberately reports
    /// rather than repairs.
    func shortcutOwnership(excluding profileID: UUID?) -> ShortcutOwnership {
        guard let layout, let manifest else {
            // No profile store to consult: nothing else can hold the ID.
            return ShortcutOwnership(idsHeldElsewhere: [], isComplete: true)
        }
        var ids = Set<UUID>()
        var isComplete = true
        for profile in manifest.profiles where profile.id != profileID {
            guard let shortcuts = decodeProfileLeniently(profile.id, layout: layout) else {
                isComplete = false
                continue
            }
            ids.formUnion(shortcuts.map(\.id))
        }
        return ShortcutOwnership(idsHeldElsewhere: ids, isComplete: isComplete)
    }

    /// Shortcut ids whose usage rows are being deleted right now, with a
    /// claim COUNT per id.
    ///
    /// Ownership is decided on the main actor and the deletion runs on the
    /// `UsageTracker` actor, so there is a suspension between them — and the
    /// main actor is free to run other work across it. Without this, an import
    /// admitting one of these ids mid-flight produces a live shortcut whose
    /// history is erased a moment later, which no recovery can undo.
    ///
    /// Counted, not a set: claimants can overlap. Two profile deletions in
    /// quick succession each drain the journal, and the journal still lists
    /// the first drain's ids until that drain finishes — so both tasks
    /// legitimately claim them. With set semantics the first release would
    /// remove the second task's claim, reopening the import window while its
    /// `deleteUsage` is still in flight; a count only clears an id when every
    /// claimant has released it.
    private var usageDeletionsInFlight: [UUID: Int] = [:]

    /// Claims `ids` for deletion. Every path that can make a shortcut id live
    /// again must consult `isUsageDeletionInFlight` before admitting it.
    /// Claims nest: each reserve needs its own release.
    func reserveUsageDeletions(_ ids: [UUID]) {
        for id in ids {
            usageDeletionsInFlight[id, default: 0] += 1
        }
    }

    func releaseUsageDeletions(_ ids: [UUID]) {
        for id in ids {
            guard let count = usageDeletionsInFlight[id] else { continue }
            if count <= 1 {
                usageDeletionsInFlight[id] = nil
            } else {
                usageDeletionsInFlight[id] = count - 1
            }
        }
    }

    func isUsageDeletionInFlight(_ ids: [UUID]) -> Bool {
        ids.contains { usageDeletionsInFlight[$0] != nil }
    }

    /// Convenience for the single-shortcut deletion path.
    func isShortcutRetainedByAnotherProfile(_ shortcutID: UUID) -> Bool {
        guard let activeProfileID = locator.currentActiveProfileID() else { return false }
        return shortcutOwnership(excluding: activeProfileID).isRetainedElsewhere(shortcutID)
    }

    // MARK: - Switching

    /// Validates the target, commits the active pointer, and hands back the
    /// shortcuts for the caller to apply. The commit happens **before** any
    /// in-memory change, so a crash lands on a disk state that leads — never
    /// lags — what was applied.
    ///
    /// A refused switch writes nothing and applies nothing.
    func activateProfile(_ profileID: UUID) throws -> [AppShortcut] {
        let payload = try loadProfileForActivation(profileID)
        try commitActivation(profileID, payload: payload)
        return payload.shortcuts
    }

    /// Validates a switch target and returns its payload, **writing nothing**.
    ///
    /// Split from the commit so a caller can discard in-flight work only once
    /// the switch is known to be possible. `ShortcutProfileState` cancels the
    /// recorder, the composer draft, and any pending import before switching —
    /// work the user cannot get back — and an unreadable profile is reachable
    /// from more than one selector, so "your recording is gone and the switch
    /// failed anyway" is the one outcome with no upside.
    func loadProfileForActivation(_ profileID: UUID) throws -> ValidatedProfilePayload {
        guard layout != nil else { throw StoreError.storageUnavailable }
        guard manifest != nil else { throw StoreError.manifestQuarantined }
        return try profilePayload(in: profileID)
    }

    /// Commits a switch whose payload `loadProfileForActivation` already
    /// validated. The payload is passed in rather than re-read for the same
    /// reason migration reads once: a second read of the same path can observe
    /// a different file, and this one would commit the pointer for it.
    /// Fails when `Profiles/<profileID>.json` no longer holds `expected`.
    ///
    /// Validation and commit are not adjacent: `prepareForSwitch()` runs
    /// between them, cancelling the recorder and dismissing panels, so the
    /// window is real work rather than a few instructions. If another process
    /// rewrites the profile in that window, committing anyway would arm and
    /// mirror a payload the canonical file no longer contains — the runtime
    /// would claim to be on that profile while running something it does not
    /// hold, and the next launch would silently arm the other one.
    ///
    /// This narrows the window rather than closing it; nothing short of a lock
    /// can close it, and the file is not Wink's to lock. What it guarantees is
    /// that a switch never COMMITS a payload it already knows is superseded.
    private func verifyCanonicalPayload(
        _ expected: Data,
        profileID: UUID,
        layout: ShortcutProfileLayout
    ) throws {
        guard let current = try? Data(contentsOf: layout.profileDataURL(profileID)) else {
            throw StoreError.profileUnreadable(id: profileID, reason: "data file disappeared before it could be applied")
        }
        guard Self.digest(current) == Self.digest(expected) else {
            log("PROFILE_TRACE_PROFILE_CHANGED_DURING_OPERATION id=\(profileID.uuidString)")
            throw StoreError.profileChangedDuringOperation(id: profileID)
        }
    }

    /// Returns whether the compat mirror was rewritten. The switch itself
    /// never fails on derived data — SWITCH semantics tolerate a stale
    /// mirror because it is attributable and silently repairable next
    /// launch — but the caller must be able to say so rather than claim
    /// full success while shortcuts.json still describes the previous
    /// profile. Same contract as recoverManifest and DeleteOutcome.
    @discardableResult
    func commitActivation(_ profileID: UUID, payload: ValidatedProfilePayload) throws -> Bool {
        guard let layout else { throw StoreError.storageUnavailable }
        // Before the pointer moves, so a refused switch changes nothing at all.
        try verifyCanonicalPayload(payload.bytes, profileID: profileID, layout: layout)
        try commitActivePointer(profileID, layout: layout)
        pointedProfileID = profileID
        locator.setActiveProfileID(profileID)
        // The exact bytes that were validated and are about to be applied, so
        // the mirror cannot describe a different payload than the runtime is
        // running.
        return writeMirrorForActiveProfile(bytes: payload.bytes, profileID: profileID, layout: layout)
    }

    // MARK: - CRUD

    struct DeleteOutcome: Equatable, Sendable {
        var profiles: [ShortcutProfile]
        /// Set when the deleted profile was the active one; the caller must
        /// apply `newActiveShortcuts` to the runtime.
        var newActiveProfileID: UUID?
        var newActiveShortcuts: [AppShortcut]?
        /// Shortcut IDs that existed only in the deleted profile, so their
        /// usage history can be removed without touching another profile's.
        var exclusivelyOwnedShortcutIDs: [UUID]
        /// Set when the delete itself failed but the active-profile switch it
        /// had already committed could not be undone — the durable pointer
        /// names the successor, so the caller must apply it and report this
        /// rather than claim nothing changed.
        var unrecoverableSwitchReason: String?
        /// False when the compat rewrite was needed and refused: the delete
        /// itself committed — it cannot be blocked on derived data — but the
        /// caller must not claim full success while shortcuts.json keeps
        /// exposing the deleted profile's bindings. Same contract as
        /// `recoverManifest`.
        var mirrorRestored: Bool = true
    }

    @discardableResult
    func createProfile(
        named rawName: String,
        duplicating sourceProfileID: UUID?
    ) throws -> ShortcutProfile {
        guard let layout else { throw StoreError.storageUnavailable }
        guard var current = manifest else { throw StoreError.manifestQuarantined }
        guard current.profiles.count < ShortcutProfileManifest.maximumProfileCount else {
            throw StoreError.profileLimitReached(limit: ShortcutProfileManifest.maximumProfileCount)
        }
        if let violation = ShortcutProfileNameRules.violation(for: rawName, in: current.profiles) {
            throw StoreError.nameRejected(violation)
        }
        // A second profile is exactly what makes a missing pointer harmful,
        // so repair it here rather than discovering the problem at launch.
        if !activePointerIsDurable, let pointedProfileID {
            try commitActivePointer(pointedProfileID, layout: layout)
            activePointerIsDurable = true
        }

        // Duplication mints a fresh UUID per row, keeping shortcut IDs
        // globally unique so `usage.db` needs no profile column. Everything
        // else is copied at the JSON level rather than through the model:
        // re-encoding an `AppShortcut` drops members this build does not
        // model, which is the same data loss migration and mirroring were
        // fixed to avoid.
        var duplicatedBytes: Data?
        var contents: [AppShortcut] = []
        if let sourceProfileID {
            // Validate through the strict loader first, so an unreadable
            // source is refused before anything is written.
            _ = try shortcuts(in: sourceProfileID)
            let copy = try duplicatedProfileBytes(from: sourceProfileID, layout: layout)
            duplicatedBytes = copy.data
            contents = copy.shortcuts
        }

        let profile = ShortcutProfile(
            id: idProvider(),
            name: ShortcutProfileNameRules.trimmed(rawName),
            createdAt: dateProvider()
        )

        // Data file first: a crash before the manifest write leaves an orphan
        // (reported, never auto-imported), which is strictly safer than a
        // manifest entry pointing at a file that does not exist.
        if let duplicatedBytes {
            try writeProfileBytes(duplicatedBytes, profileID: profile.id, layout: layout)
        } else {
            try writeProfileData(contents, profileID: profile.id, layout: layout)
        }
        current.profiles.append(profile)
        try commitManifest(current, layout: layout)
        manifest = current
        log("PROFILE_TRACE_CREATED id=\(profile.id.uuidString) shortcuts=\(contents.count) duplicated=\(sourceProfileID != nil)")
        return profile
    }

    /// Rewrites only each row's `id` inside the source file's own JSON, so
    /// members `AppShortcut` does not model survive the copy.
    ///
    /// The boundary is worth stating: unmodelled members survive every
    /// *copy* in this store — migration, mirroring, import, and this — but not
    /// the first ordinary **save** of the profile, because a save re-encodes
    /// the model by definition. Preserving them through edits would require
    /// modelling them, which is exactly what a forward-compatible schema
    /// cannot do.
    private func duplicatedProfileBytes(
        from sourceProfileID: UUID,
        layout: ShortcutProfileLayout
    ) throws -> (data: Data, shortcuts: [AppShortcut]) {
        let sourceURL = layout.profileDataURL(sourceProfileID)
        guard
            let raw = try? Data(contentsOf: sourceURL),
            let rows = (try? JSONSerialization.jsonObject(with: raw)) as? [[String: Any]]
        else {
            // No model-level fallback. Re-encoding would drop members this
            // build does not model, which is the loss duplication was just
            // fixed to avoid — a silently lossy copy is worse than a refused
            // one, and the user can still export a recipe. The condition is
            // close to unreachable in practice: a payload the strict loader
            // accepted is JSON that `JSONSerialization` can also read.
            log("PROFILE_TRACE_DUPLICATE_REFUSED id=\(sourceProfileID.uuidString) reason=json_reshape_failed")
            throw StoreError.profileUnreadable(
                id: sourceProfileID,
                reason: "profile payload could not be reshaped for duplication"
            )
        }

        let rewritten = rows.map { row -> [String: Any] in
            var row = row
            row["id"] = idProvider().uuidString
            return row
        }

        guard
            let data = try? JSONSerialization.data(
                withJSONObject: rewritten,
                options: [.prettyPrinted, .sortedKeys]
            ),
            let decoded = try? JSONDecoder().decode([AppShortcut].self, from: data),
            Set(decoded.map(\.id)).count == decoded.count
        else {
            throw StoreError.profileUnreadable(
                id: sourceProfileID,
                reason: "duplicated payload did not round trip"
            )
        }

        return (data, decoded)
    }

    @discardableResult
    func renameProfile(_ profileID: UUID, to rawName: String) throws -> ShortcutProfile {
        guard let layout else { throw StoreError.storageUnavailable }
        guard var current = manifest else { throw StoreError.manifestQuarantined }
        guard let index = current.profiles.firstIndex(where: { $0.id == profileID }) else {
            throw StoreError.profileNotFound(profileID)
        }
        if let violation = ShortcutProfileNameRules.violation(
            for: rawName,
            excluding: profileID,
            in: current.profiles
        ) {
            throw StoreError.nameRejected(violation)
        }

        current.profiles[index].name = ShortcutProfileNameRules.trimmed(rawName)
        current.profiles[index].modifiedAt = dateProvider()
        try commitManifest(current, layout: layout)
        manifest = current
        return current.profiles[index]
    }

    /// Clears the persisted legacy-migration notice. Best-effort by design:
    /// dismissal is an acknowledgement, not a data operation, so a refused
    /// manifest rewrite must not block it — the worst outcome is the notice
    /// returning on the next launch, which errs in the safe direction.
    func acknowledgeLegacyMigrationFailure() {
        guard let layout, var current = manifest, current.legacyMigrationFailure != nil else { return }
        current.legacyMigrationFailure = nil
        do {
            try commitManifest(current, layout: layout)
            manifest = current
        } catch {
            log("PROFILE_TRACE_MIGRATION_NOTICE_ACK_DEFERRED reason=\(error.localizedDescription)")
        }
    }

    /// Everything a delete needs to know before it is allowed to touch
    /// anything: that the profile exists, that it is not the last one, which
    /// shortcut ids only it holds, and — when it is the active profile — that
    /// the successor is actually loadable.
    ///
    /// Separated from the delete for the same reason activation is: the caller
    /// discards the recorder, the composer draft, and any pending import
    /// before an active-profile delete, and an unreadable successor makes that
    /// delete throw. Validating first means work is only discarded for an
    /// operation that can proceed.
    struct DeletionPlan: Sendable {
        let profileID: UUID
        let index: Int
        let exclusivelyOwnedShortcutIDs: [UUID]
        let wasActive: Bool
        /// The successor and its payload, already read. Passing it forward
        /// rather than re-reading keeps this to one read of that file.
        let successor: (id: UUID, shortcuts: [AppShortcut], bytes: Data)?
    }

    func planDeletion(of profileID: UUID) throws -> DeletionPlan {
        guard let layout else { throw StoreError.storageUnavailable }
        guard let current = manifest else { throw StoreError.manifestQuarantined }
        guard let index = current.profiles.firstIndex(where: { $0.id == profileID }) else {
            throw StoreError.profileNotFound(profileID)
        }
        guard current.profiles.count > 1 else { throw StoreError.cannotDeleteLastProfile }

        let removedShortcutIDs = (decodeProfileLeniently(profileID, layout: layout) ?? []).map(\.id)
        let ownership = shortcutOwnership(excluding: profileID)
        let exclusivelyOwned = removedShortcutIDs.filter { !ownership.isRetainedElsewhere($0) }

        let wasActive = (pointedProfileID ?? locator.currentActiveProfileID()) == profileID
        var successor: (id: UUID, shortcuts: [AppShortcut], bytes: Data)?
        if wasActive {
            // The preceding entry in the visible list order, or the first
            // entry when the deleted profile was first. Deterministic, and it
            // matches what the user is looking at; `modifiedAt` was rejected
            // because ties are possible.
            let successorIndex = index == 0 ? 1 : index - 1
            let successorID = current.profiles[successorIndex].id
            let payload = try profilePayload(in: successorID)
            successor = (successorID, payload.shortcuts, payload.bytes)
        }

        return DeletionPlan(
            profileID: profileID,
            index: index,
            exclusivelyOwnedShortcutIDs: exclusivelyOwned,
            wasActive: wasActive,
            successor: successor
        )
    }

    func deleteProfile(_ profileID: UUID) throws -> DeleteOutcome {
        try deleteProfile(planDeletion(of: profileID))
    }

    func deleteProfile(_ plan: DeletionPlan) throws -> DeleteOutcome {
        guard let layout else { throw StoreError.storageUnavailable }
        guard var current = manifest else { throw StoreError.manifestQuarantined }
        let profileID = plan.profileID
        let index = plan.index
        let exclusivelyOwned = plan.exclusivelyOwnedShortcutIDs
        let wasActive = plan.wasActive

        // What the locator held before this operation. Restoring it verbatim
        // matters when the pointed profile's data was unreadable: it was nil
        // then, and putting the id back would send later saves into a profile
        // the UI is still reporting as unusable.
        let locatorBeforeDelete = locator.currentActiveProfileID()
        var newActiveProfileID: UUID?
        var newActiveShortcuts: [AppShortcut]?

        if wasActive, let successor = plan.successor {
            // Same window as a switch, and for the same reason: the plan was
            // built before `prepareForSwitch()` ran. Checked before the pointer
            // moves, so a refused delete leaves everything as it was.
            try verifyCanonicalPayload(successor.bytes, profileID: successor.id, layout: layout)
            // Commit the pointer BEFORE the manifest: a crash in between then
            // leaves a pointer that still names a profile the manifest lists,
            // i.e. a fully consistent state where the delete simply did not
            // take. The reverse order would leave a dangling pointer.
            newActiveShortcuts = successor.shortcuts
            try commitActivePointer(successor.id, layout: layout)
            pointedProfileID = successor.id
            locator.setActiveProfileID(successor.id)
            newActiveProfileID = successor.id
        }

        current.profiles.remove(at: index)
        // Committed WITH the removal, so the ids survive a crash between the
        // delete and the usage cleanup. A fire-and-forget task after the
        // manifest is written cannot be retried: the inventory needed to
        // recompute exclusivity is gone by then.
        current.pendingUsageDeletions = (current.pendingUsageDeletions ?? []) + exclusivelyOwned
        do {
            try commitManifest(current, layout: layout)
        } catch let manifestError {
            // The pointer is already committed and the locator already moved.
            // Left as is, the runtime would keep serving the deleted profile's
            // bindings while every subsequent save landed in the successor's
            // file — overwriting a profile the user never switched to.
            guard wasActive else { throw manifestError }

            // Undo the half-applied switch so the failure is total.
            var rolledBack = true
            do {
                try commitActivePointer(profileID, layout: layout)
            } catch {
                rolledBack = false
            }

            guard !rolledBack else {
                pointedProfileID = profileID
                locator.setActiveProfileID(locatorBeforeDelete)
                throw manifestError
            }

            // Whatever failed the manifest write — a full or read-only volume
            // — can fail this write too. `active.json` durably names the
            // successor now, so claiming a total rollback would be a lie the
            // next relaunch immediately exposes. The only state with no
            // divergence between memory and disk is to accept the switch and
            // report it.
            log("PROFILE_TRACE_DELETE_ROLLBACK_FAILED id=\(profileID.uuidString) active=\(newActiveProfileID?.uuidString ?? "none")")

            // The switch stuck, so the mirror has to follow it: the runtime
            // and the locator are on the successor now, and leaving the compat
            // file describing the former active profile would point the E2E
            // harness and a downgraded build at bindings nothing is running.
            var stuckMirrorRestored = true
            if let newActiveProfileID, let newActiveShortcuts {
                stuckMirrorRestored = writeMirrorForActiveProfile(bytes: plan.successor?.bytes, profileID: newActiveProfileID, layout: layout)
            }

            // Stop here. The durable manifest still lists the profile, so
            // publishing the reduced list in memory — or unlinking the data
            // file, which can succeed even on a volume that refused the
            // metadata writes — would make the profile vanish for this session
            // and come back unreadable after a relaunch, while the UI said the
            // delete failed. Nothing was deleted; only the switch stuck.
            return DeleteOutcome(
                profiles: manifest?.profiles ?? current.profiles,
                newActiveProfileID: newActiveProfileID,
                newActiveShortcuts: newActiveShortcuts,
                exclusivelyOwnedShortcutIDs: [],
                unrecoverableSwitchReason: manifestError.localizedDescription,
                mirrorRestored: stuckMirrorRestored
            )
        }
        manifest = current

        var mirrorRestored = true
        if let newActiveProfileID, let newActiveShortcuts {
            mirrorRestored = writeMirrorForActiveProfile(bytes: plan.successor?.bytes, profileID: newActiveProfileID, layout: layout)
            if !mirrorRestored {
                log("PROFILE_TRACE_DELETE_MIRROR_STALE active=\(newActiveProfileID.uuidString)")
            }
        }

        // Best effort: a failed unlink leaves an orphan, which is reported on
        // the next load and never resurrected.
        do {
            try fileManager.removeItem(at: layout.profileDataURL(profileID))
        } catch {
            log("PROFILE_TRACE_ORPHAN id=\(profileID.uuidString) reason=delete_unlink_failed")
        }

        log("PROFILE_TRACE_DELETED id=\(profileID.uuidString) exclusiveShortcuts=\(exclusivelyOwned.count)")

        return DeleteOutcome(
            profiles: current.profiles,
            newActiveProfileID: newActiveProfileID,
            newActiveShortcuts: newActiveShortcuts,
            exclusivelyOwnedShortcutIDs: exclusivelyOwned,
            mirrorRestored: mirrorRestored
        )
    }

    /// Shortcut ids whose usage rows are owed a deletion, recorded durably by
    /// `deleteProfile` so a crash cannot strand them.
    func pendingUsageDeletions() -> [UUID] {
        manifest?.pendingUsageDeletions ?? []
    }

    /// Splits the journal into ids that are safe to delete now and ids some
    /// profile still holds.
    ///
    /// `deleteProfile` computed exclusivity against the inventory as it stood
    /// at that moment, and journalled the answer so a crash could not strand
    /// it. That answer is not durable: a manifest restored from a backup
    /// beside newer profile data files can list a deletion for an id a live
    /// profile still uses, and deleting a live shortcut's history is exactly
    /// the loss the exclusivity rule exists to prevent. So the question is
    /// asked again at the moment of the deletion, against the profiles that
    /// exist now.
    ///
    /// Retained ids stay journalled rather than being dropped, matching the
    /// fail-closed rule the rest of this path uses: an unreadable sibling
    /// makes every id look retained, and a stale journal entry costs nothing
    /// while a wrong deletion cannot be undone.
    func drainableUsageDeletions() -> (deletable: [UUID], retained: [UUID]) {
        let ids = pendingUsageDeletions()
        guard !ids.isEmpty else { return ([], []) }
        let ownership = shortcutOwnership(excluding: nil)
        var deletable: [UUID] = []
        var retained: [UUID] = []
        for id in ids {
            if ownership.isRetainedElsewhere(id) {
                retained.append(id)
            } else {
                deletable.append(id)
            }
        }
        if !retained.isEmpty {
            log("PROFILE_TRACE_USAGE_JOURNAL_RETAINED count=\(retained.count) complete=\(ownership.isComplete)")
        }
        return (deletable, retained)
    }

    /// Called after the rows are actually gone. Clearing the journal is a
    /// separate commit on purpose: if it fails, the ids are retried rather
    /// than silently dropped.
    func clearPendingUsageDeletions(_ ids: [UUID]) {
        guard let layout, var current = manifest, current.pendingUsageDeletions?.isEmpty == false else { return }
        let remaining = (current.pendingUsageDeletions ?? []).filter { !ids.contains($0) }
        current.pendingUsageDeletions = remaining.isEmpty ? nil : remaining
        do {
            try commitManifest(current, layout: layout)
            manifest = current
        } catch {
            log("PROFILE_TRACE_USAGE_JOURNAL_NOT_CLEARED count=\(ids.count)")
        }
    }

    // MARK: - Recovery actions

    /// The single explicit action that overwrites a quarantined manifest.
    /// Safe because a byte-identical copy was preserved first; this re-attempts
    /// that preservation in case the earlier attempt failed.
    func recoverManifest() throws -> (loaded: LoadedProfiles, mirrorRestored: Bool) {
        guard let layout else { throw StoreError.storageUnavailable }

        // The UI promises the unreadable file was kept. If it cannot be kept,
        // the recovery must not proceed — replacing the manifest would lose
        // the profile inventory while the banner claimed a copy exists.
        if fileManager.fileExists(atPath: layout.manifestURL.path) {
            // Present but unreadable is the case that matters: the directory
            // can still permit an atomic replacement, so skipping the guard
            // here would replace a file whose contents were never captured.
            guard let existing = try? Data(contentsOf: layout.manifestURL) else {
                log("PROFILE_TRACE_RECOVER_REFUSED reason=manifest_unreadable_for_backup")
                throw StoreError.writeFailed(
                    path: layout.manifestURL.path,
                    reason: "could not read the profile list in order to preserve it"
                )
            }
            guard preserveRejectedPayload(existing, originalURL: layout.manifestURL) != nil else {
                log("PROFILE_TRACE_RECOVER_REFUSED reason=preserve_failed")
                throw StoreError.writeFailed(
                    path: layout.manifestURL.path,
                    reason: "could not preserve the unreadable profile list"
                )
            }
        }

        let now = dateProvider()
        let profile = ShortcutProfile(
            id: idProvider(),
            name: String(localized: "Default", bundle: WinkResourceBundle.bundle),
            createdAt: now
        )

        // The manifest is written LAST because stage 1 of the load reads it
        // first: it is the commit point of a recovery exactly as `active.json`
        // is the commit point of a switch. Any failure before it therefore
        // leaves the state the user is already looking at — the manifest is
        // still unreadable and Recover is still offered — instead of a disk
        // that quietly advanced while the UI reported nothing had changed.
        // What is left behind is an unreferenced data file and a pointer no
        // stage consults while stage 1 fails, both of which the next recovery
        // supersedes.
        try writeProfileData([], profileID: profile.id, layout: layout)
        try commitActivePointer(profile.id, layout: layout)
        try commitManifest(ShortcutProfileManifest(profiles: [profile]), layout: layout)

        manifest = ShortcutProfileManifest(profiles: [profile])
        pointedProfileID = profile.id
        locator.setActiveProfileID(profile.id)
        // Every other active-profile transition refreshes the mirror; without
        // it the E2E harness and a downgraded build would keep reading the
        // pre-recovery bindings until some later save happened to repair it.
        //
        // But stage 1 stopped on the damaged manifest, so the mirror
        // classification never ran and an older build's edits to
        // shortcuts.json have never been examined. Preserving first is what
        // keeps the universal rule true here too: the mirror is never
        // overwritten until a byte-identical copy exists beside it.
        if let existingMirror = try? Data(contentsOf: layout.mirrorURL) {
            preserveUnknownMirror(
                existingMirror,
                digest: Self.digest(existingMirror),
                descriptor: loadMirrorDescriptor(layout: layout),
                layout: layout
            )
        }
        let mirrorRestored = writeMirrorForActiveProfile(profileID: profile.id, layout: layout)
        if !mirrorRestored {
            // Recovery itself must still complete — it is the only way out
            // of quarantine, and the mirror is derived data — but the caller
            // has to know: until a later successful rewrite, the E2E harness
            // and a downgraded build keep reading the pre-recovery bindings.
            log("PROFILE_TRACE_RECOVERY_MIRROR_STALE id=\(profile.id.uuidString)")
        }
        log("PROFILE_TRACE_RECOVERED id=\(profile.id.uuidString)")

        return (
            LoadedProfiles(
                profiles: [profile],
                activeProfileID: profile.id,
                activeShortcuts: [],
                unreadableProfileIDs: [],
                orphanProfileIDs: orphanProfileIDs(layout: layout, manifest: ShortcutProfileManifest(profiles: [profile])),
                duplicateShortcutIDs: [],
                foreignMirror: nil
            ),
            mirrorRestored
        )
    }

    /// Adopts an externally modified `shortcuts.json` into the profile the
    /// mirror described. Returns the adopted shortcuts when that profile is
    /// the active one, so the caller can apply them to the runtime.
    @discardableResult
    func adoptForeignMirror(_ mirror: ForeignMirror) throws -> [AppShortcut]? {
        guard let layout else { throw StoreError.storageUnavailable }
        // The offer was captured when the edit was first noticed; the file may
        // have been written AGAIN between then and the user's click. Adopting
        // the captured bytes anyway would roll the disk back to the older edit
        // — and if the later writer also refreshed the descriptor, the mirror
        // write below would classify the newer bytes as Wink's own payload and
        // overwrite their last copy with no preservation. Only a readable file
        // holding different bytes refuses: a missing or unreadable file has
        // nothing this write can destroy (`writeMirror`'s own guards keep
        // covering those states), and in the interrupted-migration recovery
        // the captured bytes can be the last copy anywhere, so refusing on
        // absence would block the only recovery the user has. Checked first:
        // every check below evaluates the offer, and a stale offer should be
        // refreshed before it is judged.
        if let currentBytes = try? Data(contentsOf: layout.mirrorURL),
           Self.digest(currentBytes) != Self.digest(mirror.rawBytes) {
            // EXCEPT when the intervening write is provably Wink's OWN
            // rewrite for the ACTIVE profile and the offer targets a
            // DIFFERENT profile: an ordinary A→B switch rewrites the mirror
            // to B (preserving the offered bytes first — writeMirror's
            // guard), and refusing here would dissolve the only UI path for
            // importing A's captured edit, leaving it recoverable solely
            // from the preservation file. That adoption installs into A's
            // data file and leaves B's mirror exactly as it stands, so
            // nothing rolls back. The descriptor-digest match is the same
            // "Wink wrote these exact bytes" reading detectForeignMirror
            // uses — an external re-edit breaks it and still refuses — and
            // an offer for the ACTIVE profile keeps refusing outright:
            // there the adoption WOULD roll data and mirror back over
            // Wink's own newer payload, whose only copy is what it would
            // overwrite.
            let descriptor = loadMirrorDescriptor(layout: layout)
            let activeProfileID = locator.currentActiveProfileID()
            let ownRewriteForActive = activeProfileID != nil
                && descriptor?.profileID == activeProfileID
                && descriptor?.sha256 == Self.digest(currentBytes)
                && mirror.profileID != activeProfileID
            guard ownRewriteForActive else {
                log("PROFILE_TRACE_IMPORT_REFUSED reason=mirror_changed_since_offer")
                throw StoreError.foreignMirrorChangedSinceOffer
            }
            log("PROFILE_TRACE_IMPORT_FROM_SNAPSHOT profile=\(mirror.profileID.uuidString)")
        }
        // Admitting an id whose rows are being deleted right now would leave a
        // live shortcut with its history erased moments later. Refusing is
        // recoverable — the offer stays and the drain finishes in milliseconds
        // — while the deletion is not.
        if let incoming = mirror.shortcuts, isUsageDeletionInFlight(incoming.map(\.id)) {
            log("PROFILE_TRACE_IMPORT_REFUSED reason=usage_deletion_in_flight")
            throw StoreError.usageDeletionInFlight
        }
        guard manifest?.profile(id: mirror.profileID) != nil else {
            throw StoreError.profileNotFound(mirror.profileID)
        }
        guard let shortcuts = mirror.shortcuts else {
            throw StoreError.profileUnreadable(id: mirror.profileID, reason: "foreign mirror does not decode")
        }
        // `writeProfileBytes` bypasses `PersistenceService`'s validation by
        // design (it exists to preserve bytes), so uniqueness is enforced here
        // rather than trusted from the decode.
        guard Set(shortcuts.map(\.id)).count == shortcuts.count else {
            throw StoreError.profileUnreadable(id: mirror.profileID, reason: "duplicate shortcut id")
        }
        // Uniqueness WITHIN the payload is not enough: global uniqueness
        // across profiles is what lets `usage.db` stay keyed by shortcut UUID
        // with no profile column, and an import is the one path that can
        // introduce IDs a sibling already owns. Fails closed — an unreadable
        // sibling could be holding any of them.
        let ownership = shortcutOwnership(excluding: mirror.profileID)
        if let collision = shortcuts.map(\.id).first(where: { ownership.isRetainedElsewhere($0) }) {
            log("PROFILE_TRACE_IMPORT_REFUSED id=\(collision.uuidString) reason=cross_profile_duplicate")
            throw StoreError.profileUnreadable(
                id: mirror.profileID,
                reason: "shortcut id already belongs to another profile"
            )
        }

        // The ORIGINAL bytes, always. A re-encoding would drop members this
        // build does not model, which is exactly what this import is meant to
        // rescue.
        try writeProfileBytes(mirror.rawBytes, profileID: mirror.profileID, layout: layout)
        log("PROFILE_TRACE_FOREIGN_MIRROR_ADOPTED profile=\(mirror.profileID.uuidString) shortcuts=\(shortcuts.count)")

        // Startup clears the locator when the active profile's data file is
        // missing, and then offers that file as an importable mirror. Writing
        // it repaired the profile, so finish the recovery here: re-commit the
        // pointer and hand the shortcuts back. Without this the import reports
        // success while the runtime stays at zero armed shortcuts until the
        // next relaunch.
        // Whether this import must FINISH A RECOVERY is decided by the
        // missing locator alone. The old fileExists precondition here let an
        // external deletion between writeProfileBytes and this line fall
        // through to the nil-active-profile return — a success report, a
        // cleared offer, and zero shortcuts armed. With the precondition
        // gone, the canonical recheck inside commitActivation reads the file
        // itself and reports the disappearance as a refusal.
        if locator.currentActiveProfileID() == nil,
           manifest?.profile(id: mirror.profileID) != nil {
            let adopted: [AppShortcut]?
            var mirrorLandedDuringActivation = false
            do {
                // The EXACT imported payload, never a re-read: between
                // `writeProfileBytes` above and this commit, another writer
                // can replace the file, and activating a re-read would apply
                // payload B while the mirror below is verified against A —
                // runtime and compat diverging under a success banner.
                // `commitActivation`'s canonical recheck (the same one every
                // explicit switch runs) turns that race into
                // `profileChangedDuringOperation` instead.
                mirrorLandedDuringActivation = try commitActivation(
                    mirror.profileID,
                    payload: ValidatedProfilePayload(shortcuts: shortcuts, bytes: mirror.rawBytes)
                )
                adopted = shortcuts
            } catch let error as StoreError {
                if case .profileChangedDuringOperation = error {
                    // Nothing was activated and the file no longer holds the
                    // imported payload — "the import landed" would be false.
                    // The error's own message (changed underneath, try again)
                    // is the honest one.
                    throw error
                }
                if case .profileUnreadable = error {
                    // The canonical recheck found the file gone or unreadable
                    // — the pre-pointer refusal for an external DELETION in
                    // the same window. Same rule: nothing was activated, so
                    // the refusal speaks for itself.
                    throw error
                }
                // The data file above is already repaired: reporting this as
                // an ordinary writeFailed would tell the user nothing was
                // changed, which is false, and hide that a retry only needs
                // to finish the activation.
                log("PROFILE_TRACE_IMPORT_ACTIVATION_INCOMPLETE profile=\(mirror.profileID.uuidString)")
                throw StoreError.importCommittedButActivationIncomplete
            } catch {
                log("PROFILE_TRACE_IMPORT_ACTIVATION_INCOMPLETE profile=\(mirror.profileID.uuidString)")
                throw StoreError.importCommittedButActivationIncomplete
            }
            // The activation's own mirror write follows SWITCH semantics —
            // a refused rewrite is tolerated because a stale mirror is
            // attributable and silently repairable next launch. An IMPORT
            // cannot borrow that tolerance: it is about to clear the offer,
            // so the check the other two branches make runs here too — and
            // commitActivation now REPORTS whether its write landed, so a
            // fully successful recovery is never re-written (which could
            // only manufacture a fresh transient failure) nor re-read.
            guard mirrorLandedDuringActivation
                || writeMirrorForActiveProfile(bytes: mirror.rawBytes, profileID: mirror.profileID, layout: layout) else {
                log("PROFILE_TRACE_IMPORT_MIRROR_NOT_RESTORED active=\(mirror.profileID.uuidString)")
                throw StoreError.importCommittedButMirrorNotRestored
            }
            return adopted
        }

        // The mirror always describes the ACTIVE profile. Importing into an
        // inactive one must not leave that profile's bindings in the file the
        // E2E harness and a downgraded build read.
        guard let activeProfileID = locator.currentActiveProfileID() else { return nil }
        if activeProfileID == mirror.profileID {
            // Same rule as the inactive branch below: the import itself
            // landed, but reporting success while the compat file could not
            // be rewritten (the preflight deliberately lets an unreadable
            // file through, and `writeMirror` then refuses to replace it)
            // would clear the banner while the E2E harness and a downgraded
            // build keep reading a file that misrepresents the profile.
            guard writeMirrorForActiveProfile(bytes: mirror.rawBytes, profileID: activeProfileID, layout: layout) else {
                log("PROFILE_TRACE_IMPORT_MIRROR_NOT_RESTORED active=\(activeProfileID.uuidString)")
                throw StoreError.importCommittedButMirrorNotRestored
            }
            return shortcuts
        }

        // The import itself landed, but the compat file still holds the
        // INACTIVE profile's bindings until this restore succeeds. Reporting
        // success here would clear the banner while the E2E harness and a
        // downgraded build keep reading the wrong profile, with nothing left
        // on screen to say so.
        guard writeMirrorForActiveProfile(profileID: activeProfileID, layout: layout) else {
            log("PROFILE_TRACE_IMPORT_MIRROR_NOT_RESTORED active=\(activeProfileID.uuidString)")
            throw StoreError.importCommittedButMirrorNotRestored
        }
        return nil
    }

    /// Keeps the profile and overwrites the externally modified file. Only the
    /// derived copy is rewritten; no profile data changes.
    /// Returns false when there is no active profile to rewrite the mirror
    /// from — the interrupted-migration state. The caller must keep offering
    /// the import in that case rather than clearing the only recovery the user
    /// has.
    @discardableResult
    func discardForeignMirror(activeShortcuts: [AppShortcut]) -> Bool {
        guard let layout, let activeProfileID = locator.currentActiveProfileID() else { return false }
        // Reporting success when the file still holds the foreign edit would
        // clear the banner and leave the user believing they chose to keep
        // their profile, while the compat file says otherwise.
        guard writeMirrorForActiveProfile(profileID: activeProfileID, layout: layout) else {
            log("PROFILE_TRACE_FOREIGN_MIRROR_DISCARD_FAILED profile=\(activeProfileID.uuidString)")
            return false
        }
        log("PROFILE_TRACE_FOREIGN_MIRROR_DISCARDED profile=\(activeProfileID.uuidString)")
        return true
    }

    // MARK: - Diagnostics helpers

    private func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
        diagnosticClient.log(message)
    }

    private func preserveRejectedPayload(_ data: Data, originalURL: URL) -> String? {
        let baseName = originalURL.deletingPathExtension().lastPathComponent
        let pathExtension = originalURL.pathExtension.isEmpty ? "json" : originalURL.pathExtension
        let backupURL = originalURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(baseName).load-failure-\(backupIDProvider()).\(pathExtension)")

        do {
            // Durable for the same reason as the mirror copy: `recoverManifest`
            // replaces the quarantined file, and it is allowed to do so only
            // because this copy exists. Every other caller merely records a
            // payload it is leaving alone, where the sync costs nothing that
            // matters.
            try writeClient.writeDurable(data, backupURL)
            return backupURL.path
        } catch {
            log("Failed to preserve rejected profile payload: path=\(originalURL.path) reason=\(error.localizedDescription)")
            return nil
        }
    }

    private func preservedCopyPath(from error: Error) -> String? {
        guard let loadError = error as? PersistenceService.LoadError else { return nil }
        switch loadError {
        case let .decodeFailed(_, _, preservedCopyPath),
             let .duplicateShortcutID(_, _, preservedCopyPath):
            return preservedCopyPath
        case .storageUnavailable, .fileReadFailed:
            return nil
        }
    }
}
