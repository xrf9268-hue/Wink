import ApplicationServices
import Foundation

enum EventTapCreationPhase: String, Equatable, Sendable {
    case initial
    case replacement
}

struct EventTapCreationContext: Equatable, Sendable {
    let generation: UInt64
    let phase: EventTapCreationPhase
    let attempt: Int
}

protocol EventTapRunLoopThread: AnyObject {
    var identity: String { get }
    var threadID: UInt64? { get }
    var hasExited: Bool { get }
    var isAlive: Bool { get }

    func start()
    func addSource(_ source: CFRunLoopSource)
    func removeSource(_ source: CFRunLoopSource)
    func cancelAndWait()
}

struct EventTapRuntimeFactory {
    let makeThread: (UInt64) -> any EventTapRunLoopThread
    let makeTap: (
        EventTapCreationContext,
        CGEventMask,
        CGEventTapCallBack,
        UnsafeMutableRawPointer
    ) -> CFMachPort?
    let makeSource: (EventTapCreationContext, CFMachPort) -> CFRunLoopSource?
    let setTapEnabled: (CFMachPort, Bool) -> Void
    let invalidateTap: (CFMachPort) -> Void
    let now: () -> CFAbsoluteTime

    @MainActor static let live = EventTapRuntimeFactory(
        makeThread: { generation in
            let thread = BackgroundRunLoopThread()
            thread.name = "Wink Hyper Event Tap g\(generation)"
            return thread
        },
        makeTap: { _, mask, callback, userInfo in
            CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: callback,
                userInfo: userInfo
            )
        },
        makeSource: { _, tap in
            CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        },
        setTapEnabled: { tap, enabled in
            CGEvent.tapEnable(tap: tap, enable: enabled)
        },
        invalidateTap: { tap in
            CFMachPortInvalidate(tap)
        },
        now: { CFAbsoluteTimeGetCurrent() }
    )
}

final class EventTapOwnedSession {
    let generation: UInt64
    let thread: any EventTapRunLoopThread
    let box: EventTapBox
    var tap: CFMachPort?
    var source: CFRunLoopSource?

    init(
        generation: UInt64,
        thread: any EventTapRunLoopThread,
        box: EventTapBox
    ) {
        self.generation = generation
        self.thread = thread
        self.box = box
    }

    var userInfo: UnsafeMutableRawPointer {
        UnsafeMutableRawPointer(Unmanaged.passUnretained(box).toOpaque())
    }
}

struct EventTapOwnershipSnapshot: Equatable, Sendable {
    let generation: UInt64
    let lifecycleState: EventTapLifecycleState
    let ownerCount: Int
    let ready: Bool
    let threadIdentity: String?
    let threadID: UInt64?
    let threadAlive: Bool
    let tapCreates: Int
    let tapReleases: Int
    let tapOwned: Int
    let sourceCreates: Int
    let sourceReleases: Int
    let sourceOwned: Int
    let boxCreates: Int
    let boxReleases: Int
    let boxOwned: Int
    let threadCreates: Int
    let threadReleases: Int
    let threadOwned: Int
    let keyCallbackDeliveries: Int
    let staleCallbacksDiscarded: Int

    func logMessage(event: String, scenario: String = "production") -> String {
        let threadIDText = threadID.map(String.init) ?? "nil"
        let threadIdentityText = threadIdentity ?? "nil"
        return "EVENT_TAP_OWNERSHIP scenario=\(scenario) event=\(event) generation=\(generation) ownerCount=\(ownerCount) ready=\(ready) threadId=\(threadIDText) threadIdentity=\(threadIdentityText) threadAlive=\(threadAlive) activeThreads=\(threadOwned) tapCreates=\(tapCreates) tapReleases=\(tapReleases) tapOwned=\(tapOwned) sourceCreates=\(sourceCreates) sourceReleases=\(sourceReleases) sourceOwned=\(sourceOwned) boxCreates=\(boxCreates) boxReleases=\(boxReleases) boxOwned=\(boxOwned) keyCallbackDeliveries=\(keyCallbackDeliveries) staleCallbacksDiscarded=\(staleCallbacksDiscarded)"
    }
}

struct EventTapOwnershipLedger {
    var tapCreates = 0
    var tapReleases = 0
    var sourceCreates = 0
    var sourceReleases = 0
    var boxCreates = 0
    var boxReleases = 0
    var threadCreates = 0
    var threadReleases = 0
    var keyCallbackDeliveries = 0
    var staleCallbacksDiscarded = 0

    func snapshot(
        generation: UInt64,
        lifecycleState: EventTapLifecycleState,
        owner: EventTapOwnedSession?,
        ready: Bool
    ) -> EventTapOwnershipSnapshot {
        EventTapOwnershipSnapshot(
            generation: generation,
            lifecycleState: lifecycleState,
            ownerCount: owner == nil ? 0 : 1,
            ready: ready,
            threadIdentity: owner?.thread.identity,
            threadID: owner?.thread.threadID,
            threadAlive: owner?.thread.isAlive == true,
            tapCreates: tapCreates,
            tapReleases: tapReleases,
            tapOwned: tapCreates - tapReleases,
            sourceCreates: sourceCreates,
            sourceReleases: sourceReleases,
            sourceOwned: sourceCreates - sourceReleases,
            boxCreates: boxCreates,
            boxReleases: boxReleases,
            boxOwned: boxCreates - boxReleases,
            threadCreates: threadCreates,
            threadReleases: threadReleases,
            threadOwned: threadCreates - threadReleases,
            keyCallbackDeliveries: keyCallbackDeliveries,
            staleCallbacksDiscarded: staleCallbacksDiscarded
        )
    }
}
