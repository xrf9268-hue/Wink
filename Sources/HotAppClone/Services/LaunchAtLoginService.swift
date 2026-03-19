import ServiceManagement
import os.log

private let logger = Logger(subsystem: "com.hotappclone", category: "LaunchAtLogin")

struct LaunchAtLoginService {
    private let service = SMAppService.mainApp

    var isEnabled: Bool {
        service.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try service.register()
                logger.info("Registered as login item")
            } else {
                try service.unregister()
                logger.info("Unregistered as login item")
            }
        } catch {
            logger.error("Failed to \(enabled ? "register" : "unregister") login item: \(error)")
        }
    }
}
