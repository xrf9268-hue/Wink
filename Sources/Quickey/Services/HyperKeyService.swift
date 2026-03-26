import AppKit
import os.log

private let logger = Logger(subsystem: DiagnosticLog.subsystem, category: "HyperKeyService")

private func runHidutil(_ arguments: [String]) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            logger.error("hidutil exited with status \(process.terminationStatus)")
            DiagnosticLog.log("hidutil exited with status \(process.terminationStatus)")
            return false
        }
        return true
    } catch {
        logger.error("hidutil failed: \(error.localizedDescription)")
        DiagnosticLog.log("hidutil failed: \(error.localizedDescription)")
        return false
    }
}

@MainActor
final class HyperKeyService {
    typealias HidutilRunner = @Sendable ([String]) -> Bool

    /// HID usage codes (Apple TN2450)
    nonisolated static let capsLockUsage: UInt64 = 0x700000039
    nonisolated static let f19Usage: UInt64 = 0x700000068
    /// F19 virtual keyCode (Carbon Events)
    nonisolated static let f19KeyCode: CGKeyCode = 80  // kVK_F19 = 0x50

    private let enabledKey = "hyperKeyEnabled"
    private let runner: HidutilRunner
    private let defaults: UserDefaults

    init(
        runner: @escaping HidutilRunner = runHidutil,
        defaults: UserDefaults = .standard
    ) {
        self.runner = runner
        self.defaults = defaults
    }

    private(set) var isEnabled: Bool {
        get { defaults.bool(forKey: enabledKey) }
        set { defaults.set(newValue, forKey: enabledKey) }
    }

    func enable() {
        guard applyMapping() else {
            logger.error("Failed to enable Hyper Key")
            DiagnosticLog.log("Failed to enable Hyper Key")
            return
        }
        isEnabled = true
        logger.info("Hyper Key enabled")
        DiagnosticLog.log("Hyper Key enabled")
    }

    func disable() {
        guard clearMapping() else {
            logger.error("Failed to disable Hyper Key")
            DiagnosticLog.log("Failed to disable Hyper Key")
            return
        }
        isEnabled = false
        logger.info("Hyper Key disabled")
        DiagnosticLog.log("Hyper Key disabled")
    }

    /// Re-apply mapping on app launch if previously enabled (hidutil mappings don't survive reboot).
    func reapplyIfNeeded() {
        guard isEnabled else { return }
        guard applyMapping() else { return }
        logger.info("Hyper Key mapping re-applied on launch")
        DiagnosticLog.log("Hyper Key mapping re-applied on launch")
    }

    /// Clear mapping on app exit to restore normal Caps Lock behavior.
    func clearMappingIfEnabled() {
        guard isEnabled else { return }
        guard clearMapping() else { return }
        logger.info("Hyper Key mapping cleared on exit")
        DiagnosticLog.log("Hyper Key mapping cleared on exit")
    }

    // MARK: - hidutil

    private func applyMapping() -> Bool {
        // CapsLockDelayOverride=0 removes the ~100ms press-duration threshold
        // that macOS 15+ requires before a Caps Lock press registers.
        // (Undocumented hidutil property; see CapsLockNoDelay, Karabiner-Elements #3949.)
        let json = """
        {"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":\(Self.capsLockUsage),"HIDKeyboardModifierMappingDst":\(Self.f19Usage)}],"CapsLockDelayOverride":0}
        """
        return runner(["property", "--set", json])
    }

    private func clearMapping() -> Bool {
        // CapsLockDelayOverride is not explicitly reset here. hidutil properties
        // do not survive reboot (Apple TN2450), so the override clears naturally.
        return runner(["property", "--set", "{\"UserKeyMapping\":[]}"])
    }
}
