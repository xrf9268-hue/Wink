import AppKit

struct RestoreContext: Sendable, Equatable {
    let targetBundleIdentifier: String
    let previousBundleIdentifier: String?
    let previousPID: pid_t?
    let previousBundleURL: URL?
    let capturedAt: CFAbsoluteTime
    let generation: Int
}
