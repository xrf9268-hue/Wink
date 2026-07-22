import AppKit
import Foundation
import Testing
@testable import Wink

@MainActor
private func ensureAppKitApplication() {
    _ = NSApplication.shared
}

@MainActor
private func drainMainRunLoop(_ seconds: TimeInterval = 0.05) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

private func makeCandidate(
    _ name: String,
    _ bundleIdentifier: String,
    isRunning: Bool
) -> SearchPaletteCandidate {
    SearchPaletteCandidate(
        entry: AppEntry(id: bundleIdentifier, name: name, url: URL(fileURLWithPath: "/Applications/\(name).app")),
        normalizedName: name.lowercased(),
        keycap: nil,
        isRunning: isRunning
    )
}

@MainActor
private final class SearchPaletteHUDHarness {
    var candidates: [SearchPaletteCandidate]
    var activatedEntries: [AppEntry] = []
    var sessionActiveCalls: [Bool] = []

    lazy var controller = SearchPaletteHUDController(
        onSessionStateChange: { [unowned self] active in self.sessionActiveCalls.append(active) },
        candidatesProvider: { [unowned self] in self.candidates },
        activate: { [unowned self] entry in
            self.activatedEntries.append(entry)
            return true
        }
    )

    init(candidates: [SearchPaletteCandidate]) {
        self.candidates = candidates
    }
}

// MARK: - P2-1: panel resizes as content changes (structural, not pixel)

/// #356 P2-1 regression: sizing only ever happened once, at `present()`.
/// Typing a query that grows the result set (or, as exercised here,
/// `refreshCandidatesIfPresented()` picking up a larger candidate set) left
/// a stale, clipped viewport. This asserts the panel's content actually
/// grows — not an exact pixel height, which would be a brittle assertion
/// against SwiftUI/AppKit layout internals.
@Test @MainActor
func presentedPanelGrowsAsTheCandidateSetGrows() throws {
    ensureAppKitApplication()
    let harness = SearchPaletteHUDHarness(candidates: [
        makeCandidate("Safari", "com.apple.Safari", isRunning: true),
    ])

    harness.controller.present()
    drainMainRunLoop()
    let panel = try #require(harness.controller.panel)
    let heightWithOneResult = panel.frame.height

    harness.candidates = (0..<8).map { index in
        makeCandidate("App \(index)", "com.example.app\(index)", isRunning: true)
    }
    harness.controller.refreshCandidatesIfPresented()
    drainMainRunLoop()
    let heightWithEightResults = panel.frame.height

    #expect(heightWithEightResults > heightWithOneResult)

    harness.controller.dismiss()
}

// MARK: - P2-7: resilience to a trigger fired before the app list is warm

/// #356 P2-7 regression: a trigger fired before `AppListProvider`'s first
/// scan lands would otherwise open onto an empty snapshot that stayed empty
/// until dismiss/reopen. `AppController` wires `AppListProvider.onRefreshCompleted`
/// to this method; this proves the presented palette actually picks up a
/// later-arriving candidate set instead of requiring the user to
/// dismiss/reopen.
@Test @MainActor
func refreshCandidatesIfPresentedPicksUpALaterArrivingCandidateSet() throws {
    ensureAppKitApplication()
    let harness = SearchPaletteHUDHarness(candidates: [])

    harness.controller.present()
    drainMainRunLoop()
    let panel = try #require(harness.controller.panel)
    let heightWhileEmpty = panel.frame.height

    harness.candidates = [
        makeCandidate("Safari", "com.apple.Safari", isRunning: true),
        makeCandidate("Terminal", "com.apple.Terminal", isRunning: true),
    ]
    harness.controller.refreshCandidatesIfPresented()
    drainMainRunLoop()

    #expect(panel.frame.height > heightWhileEmpty)

    harness.controller.dismiss()
}

@Test @MainActor
func refreshCandidatesIfPresentedIsANoOpWhenNotPresented() {
    ensureAppKitApplication()
    let harness = SearchPaletteHUDHarness(candidates: [
        makeCandidate("Safari", "com.apple.Safari", isRunning: true),
    ])

    // Never presented — must not create a panel or crash.
    harness.controller.refreshCandidatesIfPresented()

    #expect(harness.controller.panel == nil)
    #expect(!harness.controller.isPresented)
}
