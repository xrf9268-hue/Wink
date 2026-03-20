import AppKit
import os.log

private let logger = Logger(subsystem: DiagnosticLog.subsystem, category: "HyperKeyService")

@MainActor
final class HyperKeyService {
    /// HID usage codes (Apple TN2450)
    static let capsLockUsage: UInt64 = 0x700000039
    static let f19Usage: UInt64 = 0x700000068
    /// F19 virtual keyCode (Carbon Events)
    static let f19KeyCode: CGKeyCode = 80  // kVK_F19 = 0x50

    private let enabledKey = "hyperKeyEnabled"

    private(set) var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    func enable() {
        applyMapping()
        isEnabled = true
        logger.info("Hyper Key enabled")
        DiagnosticLog.log("Hyper Key enabled")
    }

    func disable() {
        clearMapping()
        isEnabled = false
        logger.info("Hyper Key disabled")
        DiagnosticLog.log("Hyper Key disabled")
    }

    /// Re-apply mapping on app launch if previously enabled (hidutil mappings don't survive reboot).
    func reapplyIfNeeded() {
        guard isEnabled else { return }
        applyMapping()
        logger.info("Hyper Key mapping re-applied on launch")
        DiagnosticLog.log("Hyper Key mapping re-applied on launch")
    }

    /// Clear mapping on app exit to restore normal Caps Lock behavior.
    func clearMappingIfEnabled() {
        guard isEnabled else { return }
        clearMapping()
        logger.info("Hyper Key mapping cleared on exit")
        DiagnosticLog.log("Hyper Key mapping cleared on exit")
    }

    // MARK: - hidutil

    private func applyMapping() {
        let json = """
        {"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":\(Self.capsLockUsage),"HIDKeyboardModifierMappingDst":\(Self.f19Usage)}]}
        """
        runHidutil(["property", "--set", json])
    }

    private func clearMapping() {
        runHidutil(["property", "--set", "{\"UserKeyMapping\":[]}"])
    }

    private func runHidutil(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { process in
            if process.terminationStatus != 0 {
                logger.error("hidutil exited with status \(process.terminationStatus)")
                DiagnosticLog.log("hidutil exited with status \(process.terminationStatus)")
            }
        }
        do {
            try process.run()
        } catch {
            logger.error("hidutil failed: \(error.localizedDescription)")
            DiagnosticLog.log("hidutil failed: \(error.localizedDescription)")
        }
    }
}
