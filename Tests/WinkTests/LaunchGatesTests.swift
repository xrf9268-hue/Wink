import Foundation
import Testing
@testable import Wink

@Suite("Launch gates")
struct LaunchGatesTests {
    @Test
    func freshInstallNeverShowsWhatsNew() {
        #expect(LaunchGates.shouldShowWhatsNew(
            currentVersion: "0.5.0",
            hasLaunchedBefore: false,
            lastSeenVersion: nil,
            hasNotes: true
        ) == false)
    }

    @Test
    func sameVersionDoesNotShowAgain() {
        #expect(LaunchGates.shouldShowWhatsNew(
            currentVersion: "0.5.0",
            hasLaunchedBefore: true,
            lastSeenVersion: "0.5.0",
            hasNotes: true
        ) == false)
    }

    @Test
    func versionChangeWithNotesShows() {
        #expect(LaunchGates.shouldShowWhatsNew(
            currentVersion: "0.6.0",
            hasLaunchedBefore: true,
            lastSeenVersion: "0.5.0",
            hasNotes: true
        ) == true)
    }

    @Test
    func upgradeFromPreFeatureBuildCountsAsVersionChange() {
        #expect(LaunchGates.shouldShowWhatsNew(
            currentVersion: "0.6.0",
            hasLaunchedBefore: true,
            lastSeenVersion: nil,
            hasNotes: true
        ) == true)
    }

    @Test
    func versionWithoutNotesStaysSilent() {
        #expect(LaunchGates.shouldShowWhatsNew(
            currentVersion: "0.6.0",
            hasLaunchedBefore: true,
            lastSeenVersion: "0.5.0",
            hasNotes: false
        ) == false)
    }

    @Test @MainActor
    func consumeWhatsNewGateFiresOncePerVersionChangeAndRecordsVersion() throws {
        let suiteName = "LaunchGatesTests.consumeGate"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        // Fresh install: records the version silently.
        #expect(AppController.consumeWhatsNewGate(
            userDefaults: defaults,
            currentVersion: "0.5.0",
            hasLaunchedBefore: false,
            hasNotes: true
        ) == false)
        #expect(defaults.string(forKey: AppController.lastSeenVersionDefaultsKey) == "0.5.0")

        // Same version relaunch: silent.
        #expect(AppController.consumeWhatsNewGate(
            userDefaults: defaults,
            currentVersion: "0.5.0",
            hasLaunchedBefore: true,
            hasNotes: true
        ) == false)

        // Upgrade: fires exactly once.
        #expect(AppController.consumeWhatsNewGate(
            userDefaults: defaults,
            currentVersion: "0.6.0",
            hasLaunchedBefore: true,
            hasNotes: true
        ) == true)
        #expect(defaults.string(forKey: AppController.lastSeenVersionDefaultsKey) == "0.6.0")

        // Relaunch after the upgrade: silent again.
        #expect(AppController.consumeWhatsNewGate(
            userDefaults: defaults,
            currentVersion: "0.6.0",
            hasLaunchedBefore: true,
            hasNotes: true
        ) == false)
    }

    @Test
    func catalogHasNotesForTheCurrentReleaseLine() {
        #expect(!WhatsNewCatalog.notes(for: "0.5.0").isEmpty)
        #expect(WhatsNewCatalog.notes(for: "0.0.1").isEmpty)
    }
}
