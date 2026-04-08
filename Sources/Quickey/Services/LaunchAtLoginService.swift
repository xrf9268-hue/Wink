import Foundation
import ServiceManagement
import os.log

private let logger = Logger(subsystem: DiagnosticLog.subsystem, category: "LaunchAtLogin")

enum LaunchAtLoginStatus: Equatable {
    case enabled
    case requiresApproval
    case disabled
    case notFound

    var isEnabled: Bool {
        self == .enabled
    }
}

enum LaunchAtLoginAvailability: String, Equatable {
    case available
    case requiresAppInApplicationsFolder
    case missingConfiguration
}

struct LaunchAtLoginSnapshot: Equatable {
    let status: LaunchAtLoginStatus
    let availability: LaunchAtLoginAvailability
}

struct LaunchAtLoginService {
    struct Client: Sendable {
        let status: @Sendable () -> SMAppService.Status
        let register: @Sendable () throws -> Void
        let unregister: @Sendable () throws -> Void
        let openSystemSettingsLoginItems: @Sendable () -> Void
        let bundleURL: @Sendable () -> URL?
        let applicationDirectories: @Sendable () -> [URL]

        init(
            status: @escaping @Sendable () -> SMAppService.Status,
            register: @escaping @Sendable () throws -> Void,
            unregister: @escaping @Sendable () throws -> Void,
            openSystemSettingsLoginItems: @escaping @Sendable () -> Void,
            bundleURL: @escaping @Sendable () -> URL? = { nil },
            applicationDirectories: @escaping @Sendable () -> [URL] = { [] }
        ) {
            self.status = status
            self.register = register
            self.unregister = unregister
            self.openSystemSettingsLoginItems = openSystemSettingsLoginItems
            self.bundleURL = bundleURL
            self.applicationDirectories = applicationDirectories
        }
    }

    private let client: Client

    init(client: Client = .live) {
        self.client = client
    }

    var snapshot: LaunchAtLoginSnapshot {
        let rawStatus = client.status()
        let mappedStatus = Self.mapStatus(rawStatus)
        let availability = Self.mapAvailability(
            mappedStatus,
            bundleURL: client.bundleURL(),
            applicationDirectories: client.applicationDirectories()
        )
        let snapshot = LaunchAtLoginSnapshot(status: mappedStatus, availability: availability)

        if snapshot.status == .notFound {
            DiagnosticLog.log(
                "LaunchAtLogin status=notFound availability=\(snapshot.availability.rawValue) bundle=\(client.bundleURL()?.path ?? "nil")"
            )
            logger.info(
                "Launch at login unavailable, availability=\(snapshot.availability.rawValue, privacy: .public)"
            )
        }

        return snapshot
    }

    var status: LaunchAtLoginStatus {
        snapshot.status
    }

    var availability: LaunchAtLoginAvailability {
        snapshot.availability
    }

    var isEnabled: Bool {
        status.isEnabled
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try client.register()
                logger.info("Registered as login item")
            } else {
                try client.unregister()
                logger.info("Unregistered as login item")
            }
        } catch {
            logger.error("Failed to \(enabled ? "register" : "unregister") login item: \(error)")
            DiagnosticLog.log("Failed to \(enabled ? "register" : "unregister") login item: \(error)")
        }
    }

    func openSystemSettingsLoginItems() {
        client.openSystemSettingsLoginItems()
    }

    private static func mapStatus(_ status: SMAppService.Status) -> LaunchAtLoginStatus {
        switch status {
        case .enabled:
            .enabled
        case .requiresApproval:
            .requiresApproval
        case .notRegistered:
            .disabled
        case .notFound:
            .notFound
        @unknown default:
            .notFound
        }
    }

    private static func mapAvailability(
        _ status: LaunchAtLoginStatus,
        bundleURL: URL?,
        applicationDirectories: [URL]
    ) -> LaunchAtLoginAvailability {
        guard status == .notFound else {
            return .available
        }

        guard let bundleURL else {
            return .missingConfiguration
        }

        if isInstalledInApplicationsFolder(bundleURL, applicationDirectories: applicationDirectories) {
            return .missingConfiguration
        }

        return .requiresAppInApplicationsFolder
    }

    private static func isInstalledInApplicationsFolder(
        _ bundleURL: URL,
        applicationDirectories: [URL]
    ) -> Bool {
        let resolvedBundleURL = bundleURL.standardizedFileURL.resolvingSymlinksInPath()

        return applicationDirectories
            .map { $0.standardizedFileURL.resolvingSymlinksInPath() }
            .contains { applicationsDirectory in
                resolvedBundleURL == applicationsDirectory ||
                resolvedBundleURL.path.hasPrefix(applicationsDirectory.path + "/")
            }
    }

    private static func defaultApplicationDirectories(fileManager: FileManager = .default) -> [URL] {
        let directories = fileManager.urls(for: .applicationDirectory, in: .localDomainMask)
            + fileManager.urls(for: .applicationDirectory, in: .userDomainMask)

        var seenPaths = Set<String>()

        return directories
            .map { $0.standardizedFileURL.resolvingSymlinksInPath() }
            .filter { seenPaths.insert($0.path).inserted }
    }
}

extension LaunchAtLoginService.Client {
    static let live = LaunchAtLoginService.Client(
        status: { SMAppService.mainApp.status },
        register: { try SMAppService.mainApp.register() },
        unregister: { try SMAppService.mainApp.unregister() },
        openSystemSettingsLoginItems: { SMAppService.openSystemSettingsLoginItems() },
        bundleURL: { Bundle.main.bundleURL },
        applicationDirectories: { LaunchAtLoginService.defaultApplicationDirectories() }
    )
}
