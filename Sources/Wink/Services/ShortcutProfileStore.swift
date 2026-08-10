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

        static let live = WriteClient { data, url in
            try data.write(to: url, options: .atomic)
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
    func makeActiveProfilePersistenceService() -> PersistenceService {
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
                Self.writeMirror(
                    data: data,
                    profileID: profileID,
                    layout: layout,
                    writeClient: writeClient,
                    diagnosticClient: diagnosticClient
                )
            }
        )
    }

    // MARK: - Load

    func load() -> LoadState {
        guard let layout else {
            manifest = nil
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
            Set(decodedManifest.profiles.map(\.id)).count == decodedManifest.profiles.count
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
            return loadActiveProfile(
                layout: layout,
                manifest: decodedManifest,
                activeProfileID: profileID
            )
        case let .ambiguous(preservedCopyPath):
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

        // Absent or unreadable. With exactly one profile there is no other
        // configuration this could be confused with, so adopting it is a
        // determination rather than a guess.
        if manifest.profiles.count == 1 {
            let only = manifest.profiles[0].id
            try? commitActivePointer(only, layout: layout)
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
        do {
            // Strict, quarantine-on-failure — the unmodified loader every
            // shortcuts.json has always used.
            activeShortcuts = try profilePersistenceService(for: dataURL).load()
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
        let foreignMirror = detectForeignMirror(
            layout: layout,
            activeProfileID: activeProfileID,
            activeShortcuts: activeShortcuts
        )

        return .ready(
            LoadedProfiles(
                profiles: manifest.profiles,
                activeProfileID: activeProfileID,
                activeShortcuts: activeShortcuts,
                unreadableProfileIDs: integrity.unreadable,
                orphanProfileIDs: integrity.orphans,
                duplicateShortcutIDs: integrity.duplicateShortcutIDs,
                foreignMirror: foreignMirror
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
        return ForeignMirror(profileID: activeProfileID, shortcuts: shortcuts)
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

        if fileManager.fileExists(atPath: layout.mirrorURL.path) {
            do {
                migrated = try profilePersistenceService(for: layout.mirrorURL).load()
                migratedBytes = try? Data(contentsOf: layout.mirrorURL)
            } catch {
                // The existing quarantine already ran and preserved a copy.
                // An empty Default profile must not then mirror itself over a
                // file that still holds the user's (possibly hand-repairable)
                // data, so the mirror write is skipped below.
                legacySourceUnreadable = true
                log("PROFILE_TRACE_MIGRATION_SOURCE_UNREADABLE reason=\(error.localizedDescription)")
            }
        }

        do {
            if let migratedBytes {
                try writeProfileBytes(migratedBytes, profileID: profileID, layout: layout)
            } else {
                try writeProfileData(migrated, profileID: profileID, layout: layout)
            }
            try commitManifest(ShortcutProfileManifest(profiles: [profile]), layout: layout)
            try commitActivePointer(profileID, layout: layout)
        } catch {
            manifest = nil
            locator.setActiveProfileID(nil)
            log("PROFILE_TRACE_MIGRATION_FAILED reason=\(error.localizedDescription)")
            return .storageUnavailable
        }

        manifest = ShortcutProfileManifest(profiles: [profile])
        locator.setActiveProfileID(profileID)

        if !legacySourceUnreadable {
            writeMirrorForActiveProfile(migrated, profileID: profileID, layout: layout)
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
                foreignMirror: nil
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
    private func detectForeignMirror(
        layout: ShortcutProfileLayout,
        activeProfileID: UUID,
        activeShortcuts: [AppShortcut]
    ) -> ForeignMirror? {
        guard let mirrorData = try? Data(contentsOf: layout.mirrorURL) else {
            // Nothing on disk to lose.
            rewriteMirror(activeShortcuts, profileID: activeProfileID, layout: layout)
            return nil
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
        if let activeData = try? Data(contentsOf: layout.profileDataURL(activeProfileID)),
           mirrorDigest == Self.digest(activeData) {
            // Current. Keep the descriptor honest so a later comparison
            // attributes correctly; the mirror bytes themselves are already
            // right, so this rewrite is a no-op on content.
            if descriptor?.profileID != activeProfileID || descriptor?.sha256 != mirrorDigest {
                rewriteMirror(activeShortcuts, profileID: activeProfileID, layout: layout)
            }
            return nil
        }

        guard let descriptor else {
            log("PROFILE_TRACE_MIRROR_UNKNOWN active=\(activeProfileID.uuidString) reason=no_descriptor")
            return nil
        }

        // Only the CURRENT digest counts as "Wink wrote this". Remembering the
        // previous one would also match a user or older build deliberately
        // restoring the immediately preceding configuration — byte-identical
        // on disk to the crash window it was meant to recognize — and this
        // branch overwrites silently. When two states cannot be told apart,
        // the safe wrong answer is to ask, not to act.
        if descriptor.sha256 == mirrorDigest {
            log("PROFILE_TRACE_MIRROR_STALE describedProfile=\(descriptor.profileID.uuidString) active=\(activeProfileID.uuidString)")
            rewriteMirror(activeShortcuts, profileID: activeProfileID, layout: layout)
            return nil
        }

        // A descriptor naming a profile that no longer exists cannot support
        // the import side of the banner, and recreating that profile would
        // resurrect exactly what D9 refuses to adopt. Unknown provenance:
        // leave both files alone.
        guard manifest?.profile(id: descriptor.profileID) != nil else {
            log("PROFILE_TRACE_MIRROR_UNKNOWN active=\(activeProfileID.uuidString) reason=descriptor_profile_deleted")
            return nil
        }

        log("PROFILE_TRACE_FOREIGN_MIRROR profile=\(descriptor.profileID.uuidString)")
        return ForeignMirror(
            profileID: descriptor.profileID,
            shortcuts: try? JSONDecoder().decode([AppShortcut].self, from: mirrorData)
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

    /// Rewrites `shortcuts.json` and its descriptor from a profile's current
    /// contents. Used to repair a mirror this build left stale (a crash
    /// between any data-file write and the mirror write) — never to resolve a
    /// foreign edit or a mirror of unknown provenance, both of which require
    /// an explicit user choice.
    func rewriteMirror(_ shortcuts: [AppShortcut], profileID: UUID, layout: ShortcutProfileLayout? = nil) {
        guard let layout = layout ?? self.layout else { return }
        writeMirrorForActiveProfile(shortcuts, profileID: profileID, layout: layout)
    }

    private func writeMirrorForActiveProfile(
        _ shortcuts: [AppShortcut],
        profileID: UUID,
        layout: ShortcutProfileLayout
    ) {
        // Prefer the profile file's own bytes so unmodelled JSON members
        // reach the mirror verbatim; a re-encoding is only a fallback for the
        // case where that file cannot be read at all.
        let data: Data
        if let raw = try? Data(contentsOf: layout.profileDataURL(profileID)) {
            data = raw
        } else if let encoded = try? PersistenceService.encodeShortcuts(shortcuts) {
            data = encoded
        } else {
            log("PROFILE_TRACE_MIRROR_FAILED reason=encode_failed")
            return
        }
        Self.writeMirror(
            data: data,
            profileID: profileID,
            layout: layout,
            writeClient: writeClient,
            diagnosticClient: diagnosticClient
        )
    }

    /// `static` and parameterized so the `@Sendable` derived-copy closure can
    /// call it without capturing the main-actor-isolated store.
    nonisolated private static func writeMirror(
        data: Data,
        profileID: UUID,
        layout: ShortcutProfileLayout,
        writeClient: WriteClient,
        diagnosticClient: DiagnosticClient
    ) {
        // The mirror is derived data written last. Its failure is reported but
        // never fails the operation that produced it, because a stale mirror
        // cannot affect this build's behavior.
        do {
            try writeClient.write(data, layout.mirrorURL)
        } catch {
            let message = "PROFILE_TRACE_MIRROR_FAILED reason=mirror_write_failed detail=\(error.localizedDescription)"
            logger.error("\(message, privacy: .public)")
            diagnosticClient.log(message)
            return
        }

        let descriptor = ShortcutProfileMirrorDescriptor(
            profileID: profileID,
            sha256: digest(data)
        )
        do {
            try writeClient.write(try metadataEncoder.encode(descriptor), layout.mirrorDescriptorURL)
        } catch {
            let message = "PROFILE_TRACE_MIRROR_FAILED reason=descriptor_write_failed detail=\(error.localizedDescription)"
            logger.error("\(message, privacy: .public)")
            diagnosticClient.log(message)
        }
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
    func shortcuts(in profileID: UUID) throws -> [AppShortcut] {
        guard let layout else { throw StoreError.storageUnavailable }
        guard manifest?.profile(id: profileID) != nil else {
            throw StoreError.profileNotFound(profileID)
        }
        do {
            return try profilePersistenceService(for: layout.profileDataURL(profileID)).load()
        } catch {
            throw StoreError.profileUnreadable(id: profileID, reason: error.localizedDescription)
        }
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
    func shortcutOwnership(excluding profileID: UUID) -> ShortcutOwnership {
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
        guard let layout else { throw StoreError.storageUnavailable }
        guard manifest != nil else { throw StoreError.manifestQuarantined }

        let shortcuts = try self.shortcuts(in: profileID)
        try commitActivePointer(profileID, layout: layout)
        locator.setActiveProfileID(profileID)
        writeMirrorForActiveProfile(shortcuts, profileID: profileID, layout: layout)
        return shortcuts
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

        // Duplication mints a fresh UUID per row, keeping shortcut IDs
        // globally unique so `usage.db` needs no profile column. Every other
        // field is copied verbatim, including the preserved invalid-target
        // gate — dropping it would re-arm a row a newer build meant to keep
        // unavailable (#404).
        let contents: [AppShortcut] = try sourceProfileID.map { sourceID in
            try shortcuts(in: sourceID).map { source in
                AppShortcut(
                    id: idProvider(),
                    appName: source.appName,
                    bundleIdentifier: source.bundleIdentifier,
                    keyEquivalent: source.keyEquivalent,
                    modifierFlags: source.modifierFlags,
                    isEnabled: source.isEnabled,
                    frontmostBehaviorOverride: source.frontmostBehaviorOverride,
                    target: source.target,
                    holdAction: source.holdAction,
                    persistedInvalidTarget: source.persistedInvalidTargetForCopy
                )
            }
        } ?? []

        let profile = ShortcutProfile(
            id: idProvider(),
            name: ShortcutProfileNameRules.trimmed(rawName),
            createdAt: dateProvider()
        )

        // Data file first: a crash before the manifest write leaves an orphan
        // (reported, never auto-imported), which is strictly safer than a
        // manifest entry pointing at a file that does not exist.
        try writeProfileData(contents, profileID: profile.id, layout: layout)
        current.profiles.append(profile)
        try commitManifest(current, layout: layout)
        manifest = current
        log("PROFILE_TRACE_CREATED id=\(profile.id.uuidString) shortcuts=\(contents.count) duplicated=\(sourceProfileID != nil)")
        return profile
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

    func deleteProfile(_ profileID: UUID) throws -> DeleteOutcome {
        guard let layout else { throw StoreError.storageUnavailable }
        guard var current = manifest else { throw StoreError.manifestQuarantined }
        guard let index = current.profiles.firstIndex(where: { $0.id == profileID }) else {
            throw StoreError.profileNotFound(profileID)
        }
        guard current.profiles.count > 1 else { throw StoreError.cannotDeleteLastProfile }

        let removedShortcutIDs = (decodeProfileLeniently(profileID, layout: layout) ?? []).map(\.id)
        let ownership = shortcutOwnership(excluding: profileID)
        let exclusivelyOwned = removedShortcutIDs.filter { !ownership.isRetainedElsewhere($0) }

        let wasActive = locator.currentActiveProfileID() == profileID
        var newActiveProfileID: UUID?
        var newActiveShortcuts: [AppShortcut]?

        if wasActive {
            // The preceding entry in the visible list order, or the first
            // entry when the deleted profile was first. Deterministic, and it
            // matches what the user is looking at; `modifiedAt` was rejected
            // because ties are possible.
            let successorIndex = index == 0 ? 1 : index - 1
            let successorID = current.profiles[successorIndex].id
            // Commit the pointer BEFORE the manifest: a crash in between then
            // leaves a pointer that still names a profile the manifest lists,
            // i.e. a fully consistent state where the delete simply did not
            // take. The reverse order would leave a dangling pointer.
            newActiveShortcuts = try shortcuts(in: successorID)
            try commitActivePointer(successorID, layout: layout)
            locator.setActiveProfileID(successorID)
            newActiveProfileID = successorID
        }

        current.profiles.remove(at: index)
        do {
            try commitManifest(current, layout: layout)
        } catch {
            // The pointer is already committed and the locator already moved,
            // but the caller will not apply the successor because this throws.
            // Left as is, the runtime would keep serving the deleted profile's
            // bindings while every subsequent save landed in the successor's
            // file — overwriting a profile the user never switched to. Undo
            // the half-applied switch so the failure is total.
            if let previousActiveProfileID = wasActive ? profileID : nil {
                try? commitActivePointer(previousActiveProfileID, layout: layout)
                locator.setActiveProfileID(previousActiveProfileID)
            }
            throw error
        }
        manifest = current

        if let newActiveProfileID, let newActiveShortcuts {
            writeMirrorForActiveProfile(newActiveShortcuts, profileID: newActiveProfileID, layout: layout)
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
            exclusivelyOwnedShortcutIDs: exclusivelyOwned
        )
    }

    // MARK: - Recovery actions

    /// The single explicit action that overwrites a quarantined manifest.
    /// Safe because a byte-identical copy was preserved first; this re-attempts
    /// that preservation in case the earlier attempt failed.
    func recoverManifest() throws -> LoadedProfiles {
        guard let layout else { throw StoreError.storageUnavailable }

        if let existing = try? Data(contentsOf: layout.manifestURL) {
            _ = preserveRejectedPayload(existing, originalURL: layout.manifestURL)
        }

        let now = dateProvider()
        let profile = ShortcutProfile(
            id: idProvider(),
            name: String(localized: "Default", bundle: WinkResourceBundle.bundle),
            createdAt: now
        )

        try writeProfileData([], profileID: profile.id, layout: layout)
        try commitManifest(ShortcutProfileManifest(profiles: [profile]), layout: layout)
        try commitActivePointer(profile.id, layout: layout)

        manifest = ShortcutProfileManifest(profiles: [profile])
        locator.setActiveProfileID(profile.id)
        log("PROFILE_TRACE_RECOVERED id=\(profile.id.uuidString)")

        return LoadedProfiles(
            profiles: [profile],
            activeProfileID: profile.id,
            activeShortcuts: [],
            unreadableProfileIDs: [],
            orphanProfileIDs: orphanProfileIDs(layout: layout, manifest: ShortcutProfileManifest(profiles: [profile])),
            duplicateShortcutIDs: [],
            foreignMirror: nil
        )
    }

    /// Adopts an externally modified `shortcuts.json` into the profile the
    /// mirror described. Returns the adopted shortcuts when that profile is
    /// the active one, so the caller can apply them to the runtime.
    @discardableResult
    func adoptForeignMirror(_ mirror: ForeignMirror) throws -> [AppShortcut]? {
        guard let layout else { throw StoreError.storageUnavailable }
        guard manifest?.profile(id: mirror.profileID) != nil else {
            throw StoreError.profileNotFound(mirror.profileID)
        }
        guard let shortcuts = mirror.shortcuts else {
            throw StoreError.profileUnreadable(id: mirror.profileID, reason: "foreign mirror does not decode")
        }

        try writeProfileData(shortcuts, profileID: mirror.profileID, layout: layout)
        log("PROFILE_TRACE_FOREIGN_MIRROR_ADOPTED profile=\(mirror.profileID.uuidString) shortcuts=\(shortcuts.count)")

        // The mirror always describes the ACTIVE profile. Importing into an
        // inactive one must not leave that profile's bindings in the file the
        // E2E harness and a downgraded build read.
        guard let activeProfileID = locator.currentActiveProfileID() else { return nil }
        if activeProfileID == mirror.profileID {
            writeMirrorForActiveProfile(shortcuts, profileID: activeProfileID, layout: layout)
            return shortcuts
        }

        let activeShortcuts = (try? self.shortcuts(in: activeProfileID)) ?? []
        writeMirrorForActiveProfile(activeShortcuts, profileID: activeProfileID, layout: layout)
        return nil
    }

    /// Keeps the profile and overwrites the externally modified file. Only the
    /// derived copy is rewritten; no profile data changes.
    func discardForeignMirror(activeShortcuts: [AppShortcut]) {
        guard let layout, let activeProfileID = locator.currentActiveProfileID() else { return }
        writeMirrorForActiveProfile(activeShortcuts, profileID: activeProfileID, layout: layout)
        log("PROFILE_TRACE_FOREIGN_MIRROR_DISCARDED profile=\(activeProfileID.uuidString)")
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
            try writeClient.write(data, backupURL)
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
