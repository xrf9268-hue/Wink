import Foundation

/// Collects values written by a callback so a test can read them from its own
/// isolation domain.
///
/// The pattern this replaces — a `nonisolated(unsafe) var` captured by the
/// callback and read after the call — is a genuine cross-domain race, not a
/// checker false positive. `EventTapBox`'s phased observer is
/// `@MainActor @Sendable` and is invoked from a `DispatchQueue.main.async`
/// hop, so the write happens on the main actor while the assertion reads from
/// the (nonisolated) test. Swift 6.2 rejects that as
/// `sending 'x' risks causing data races`; `nonisolated(unsafe)` only
/// suppressed the diagnostic and left the race in place. A lock makes the
/// write and the read share one domain for real.
final class CallbackRecorder<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    func record(_ value: Value) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(value)
    }

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var count: Int {
        values.count
    }

    var isEmpty: Bool {
        values.isEmpty
    }
}

/// Lets every block already queued on the main queue run before the caller
/// asserts.
///
/// `EventTapBox.notifyPhasedKeyEvent` delivers through
/// `DispatchQueue.main.async`. Without this drain a synchronous "nothing was
/// delivered" assertion made immediately after `handleEventTapEvent` passes
/// whether or not a delivery was scheduled, because the queued block has not
/// run yet — the assertion proves nothing. The main queue is FIFO, so awaiting
/// a main-actor round-trip guarantees any block enqueued earlier has already
/// executed.
func drainMainQueue() async {
    await MainActor.run {}
}

/// A `Sendable` mutable flag for injected closures, which cannot capture a
/// `var` under strict concurrency.
final class MutableBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); defer { lock.unlock() }; storage = newValue }
    }
}
