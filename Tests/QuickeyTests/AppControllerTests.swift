import Testing
@testable import Quickey

@Test @MainActor
func startupSequenceAppliesPersistedHyperStateBeforeStartingShortcutManager() {
    var events: [String] = []

    AppController.runStartupSequence(
        loadShortcuts: {
            events.append("load")
            return []
        },
        replaceShortcuts: { _ in
            events.append("replace")
        },
        reapplyHyperIfNeeded: {
            events.append("reapplyHyper")
        },
        isHyperEnabled: {
            events.append("readHyperEnabled")
            return true
        },
        setHyperKeyEnabled: { enabled in
            events.append("setHyper:\(enabled)")
        },
        startShortcutManager: {
            events.append("startShortcutManager")
        },
        installMenuBar: {
            events.append("installMenuBar")
        }
    )

    #expect(events == [
        "load",
        "replace",
        "reapplyHyper",
        "readHyperEnabled",
        "setHyper:true",
        "startShortcutManager",
        "installMenuBar"
    ])
}
