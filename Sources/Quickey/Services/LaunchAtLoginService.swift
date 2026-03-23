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

struct LaunchAtLoginService {
    struct Client: Sendable {
        let status: @Sendable () -> SMAppService.Status
        let register: @Sendable () throws -> Void
        let unregister: @Sendable () throws -> Void
        let openSystemSettingsLoginItems: @Sendable () -> Void
    }

    private let client: Client

    init(client: Client = .live) {
        self.client = client
    }

    var status: LaunchAtLoginStatus {
        Self.mapStatus(client.status())
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
}

extension LaunchAtLoginService.Client {
    static let live = LaunchAtLoginService.Client(
        status: { SMAppService.mainApp.status },
        register: { try SMAppService.mainApp.register() },
        unregister: { try SMAppService.mainApp.unregister() },
        openSystemSettingsLoginItems: { SMAppService.openSystemSettingsLoginItems() }
    )
}
