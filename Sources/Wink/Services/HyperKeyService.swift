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
    nonisolated static let capsLockUsage: UInt64 = 0x700000039  // Keyboard CapsLock
    nonisolated static let f19Usage: UInt64 = 0x70000006E       // Keyboard F19 (0x6E = 110)
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

    /// True while a capture pause is in effect. This records the PAUSE
    /// INTERVAL itself, deliberately independent of `isEnabled`: the pause
    /// can begin while Hyper is disabled, and Hyper can be toggled either
    /// way mid-pause — in every combination, no mapping may be applied
    /// until the pause ends. Orthogonal to the persisted `isEnabled` bit
    /// (pause never persists).
    private(set) var isSuspended = false

    func enable() {
        // While suspended, applying the mapping would hand the paused
        // foreground app a consumer-less F19 — the exact #375 failure. The
        // intent persists; the mapping lands on resume.
        if !isSuspended {
            guard applyMapping() else {
                logger.error("Failed to enable Hyper Key")
                DiagnosticLog.log("Failed to enable Hyper Key")
                return
            }
        }
        isEnabled = true
        logger.info("Hyper Key enabled (suspended=\(self.isSuspended))")
        DiagnosticLog.log("Hyper Key enabled (suspended=\(isSuspended))")
    }

    func disable() {
        guard clearMapping() else {
            logger.error("Failed to disable Hyper Key")
            DiagnosticLog.log("Failed to disable Hyper Key")
            return
        }
        isEnabled = false
        // isSuspended stays: it records the pause interval, which outlives
        // an intent toggle. Re-enabling during the same pause must keep
        // deferring the mapping; the resume transition alone ends it.
        logger.info("Hyper Key disabled")
        DiagnosticLog.log("Hyper Key disabled")
    }

    /// Re-apply mapping on app launch if previously enabled (hidutil mappings don't survive reboot).
    /// Returns whether the Hyper key mapping is actually applied after the call.
    func reapplyIfNeeded() -> Bool {
        guard isEnabled else { return false }
        // Launching into a persisted pause suspends before this runs
        // (AppPreferences init fires the pause transition); re-applying here
        // would silently undo that suspension.
        guard !isSuspended else { return false }
        guard applyMapping() else {
            logger.error("Failed to re-apply Hyper Key mapping on launch")
            DiagnosticLog.log("Failed to re-apply Hyper Key mapping on launch")
            return false
        }
        logger.info("Hyper Key mapping re-applied on launch")
        DiagnosticLog.log("Hyper Key mapping re-applied on launch")
        return true
    }

    /// Hands Caps Lock back to the system for the duration of a capture
    /// pause (#375): a paused Wink consumes no F19, so leaving the mapping
    /// applied turns Caps Lock into a dead key for the very app (VM, remote
    /// desktop) the pause exists to protect. Mapping-only: `isEnabled`
    /// stays untouched, matching the never-persist rule for auto-pause.
    func suspendMappingForPause() {
        guard !isSuspended else { return }
        // The pause fact is recorded unconditionally — even with Hyper
        // disabled — so enabling Hyper mid-pause defers its mapping to
        // resume instead of arming a dead F19 under the paused app.
        isSuspended = true
        guard isEnabled else { return }
        guard clearMapping() else {
            // Mapping may still be armed during this pause; rare hidutil
            // failure, logged. Resume re-applies over it harmlessly.
            logger.error("Failed to suspend Hyper Key mapping for pause")
            DiagnosticLog.log("Failed to suspend Hyper Key mapping for pause")
            return
        }
        logger.info("Hyper Key mapping suspended for pause")
        DiagnosticLog.log("Hyper Key mapping suspended for pause")
    }

    func resumeMappingAfterPause() {
        guard isSuspended else { return }
        isSuspended = false
        guard isEnabled else { return }
        guard applyMapping() else {
            logger.error("Failed to restore Hyper Key mapping after pause")
            DiagnosticLog.log("Failed to restore Hyper Key mapping after pause")
            return
        }
        logger.info("Hyper Key mapping restored after pause")
        DiagnosticLog.log("Hyper Key mapping restored after pause")
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
        // Explicitly restore CapsLockDelayOverride to the macOS 15 default (100 ms).
        // applyMapping sets it to 0 to bypass the built-in Caps Lock press-duration
        // threshold; without writing a value back here, that override would remain
        // in effect until reboot and leak into system-wide Caps Lock behavior
        // (e.g. input-source switching becomes overly sensitive in other apps).
        return runner([
            "property",
            "--set",
            "{\"UserKeyMapping\":[],\"CapsLockDelayOverride\":100}"
        ])
    }
}
