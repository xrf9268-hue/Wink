import Foundation
import Testing
@testable import Wink

/// Reply/acknowledgement mechanics of the custom Sparkle user driver
/// (Issue #298). The service is constructed against the test bundle (no
/// SUFeedURL), so no real updater starts — the driver surface is exercised
/// directly through its pure-value seams.
///
/// SPUUserUpdateChoice raw values (SPUUserUpdateState.h): skip=0, install=1,
/// dismiss=2. Compared by rawValue so the tests need no Sparkle import.
@Suite("Update driver")
@MainActor
struct UpdateDriverTests {
    private func makeService() -> (SparkleUpdateService, PanelRecorder) {
        let service = SparkleUpdateService(bundle: Bundle(for: BundleToken.self))
        let recorder = PanelRecorder()
        service.presentUpdatePanel = { activate in recorder.presented.append(activate) }
        service.dismissUpdatePanel = { recorder.dismissCount += 1 }
        return (service, recorder)
    }

    @Test
    func scheduledFoundUpdateHoldsReplyWithoutPresentingPanel() {
        let (service, recorder) = makeService()
        var choices: [Int] = []

        service.presentUpdateFound(version: "9.9", userInitiated: false) { choice in
            choices.append(choice.rawValue)
        }

        #expect(service.updatePhase == .available(version: "9.9"))
        #expect(recorder.presented.isEmpty)
        #expect(service.debugHasUpdateReply)

        service.installUpdateNow()
        #expect(choices == [1])

        // One-shot: a second install must not double-reply.
        service.installUpdateNow()
        #expect(choices == [1])
        #expect(!service.debugHasUpdateReply)
    }

    @Test
    func userInitiatedFoundUpdatePresentsPanelWithFocus() {
        let (service, recorder) = makeService()

        service.presentUpdateFound(version: "9.9", userInitiated: true) { _ in }

        #expect(service.updatePhase == .available(version: "9.9"))
        #expect(recorder.presented == [true])
    }

    @Test
    func readyReplyOutranksStaleFoundReply() {
        let (service, _) = makeService()
        var foundChoices: [Int] = []
        var readyChoices: [Int] = []

        service.presentUpdateFound(version: "9.9", userInitiated: false) { choice in
            foundChoices.append(choice.rawValue)
        }
        service.showReady { choice in
            readyChoices.append(choice.rawValue)
        }

        service.installUpdateNow()

        // Exactly one reply, through the newer ready callback; the stale
        // found reply is discarded without being invoked.
        #expect(readyChoices == [1])
        #expect(foundChoices.isEmpty)
        #expect(!service.debugHasUpdateReply)
        #expect(!service.debugHasReadyReply)
    }

    @Test
    func remindLaterDismissesAndIdles() {
        let (service, recorder) = makeService()
        var choices: [Int] = []

        service.presentUpdateFound(version: "9.9", userInitiated: true) { choice in
            choices.append(choice.rawValue)
        }
        service.remindUpdateLater()

        #expect(choices == [2])
        #expect(service.updatePhase == .idle)
        #expect(recorder.dismissCount == 1)
    }

    @Test
    func skipSendsSkipChoice() {
        let (service, _) = makeService()
        var choices: [Int] = []

        service.presentUpdateFound(version: "9.9", userInitiated: false) { choice in
            choices.append(choice.rawValue)
        }
        service.skipUpdateVersion()

        #expect(choices == [0])
        #expect(service.updatePhase == .idle)
    }

    @Test
    func userInitiatedUpToDateHoldsAcknowledgementUntilConsumed() {
        let (service, recorder) = makeService()
        var ackCount = 0

        service.showUserInitiatedUpdateCheck(cancellation: {})
        #expect(service.updatePhase == .checking)
        #expect(recorder.presented == [true])

        service.showUpdateNotFoundWithError(TestUpdateError.sample) { ackCount += 1 }
        guard case .upToDate = service.updatePhase else {
            Issue.record("expected upToDate, got \(service.updatePhase)")
            return
        }
        #expect(ackCount == 0)
        #expect(service.debugHasPendingAcknowledgement)

        service.acknowledgeUpdateResult()
        #expect(ackCount == 1)
        #expect(service.updatePhase == .idle)
        #expect(recorder.dismissCount == 1)
    }

    @Test
    func scheduledOutcomesAcknowledgeImmediatelySoTheSessionNeverLeaks() {
        let (service, recorder) = makeService()
        var ackCount = 0

        service.showUpdateNotFoundWithError(TestUpdateError.sample) { ackCount += 1 }
        #expect(ackCount == 1)
        #expect(service.updatePhase == .idle)

        service.showUpdaterError(TestUpdateError.sample) { ackCount += 1 }
        #expect(ackCount == 2)
        #expect(service.updatePhase == .error(message: TestUpdateError.sample.localizedDescription))
        #expect(recorder.presented.isEmpty)
    }

    @Test
    func closePathsConsumeAHeldAcknowledgement() {
        let (service, _) = makeService()
        var ackCount = 0

        service.showUserInitiatedUpdateCheck(cancellation: {})
        service.showUpdateNotFoundWithError(TestUpdateError.sample) { ackCount += 1 }
        #expect(ackCount == 0)

        // Closing through the wrong-but-adjacent action must still consume
        // the acknowledgement — a leaked one wedges Sparkle's session for
        // the rest of the run.
        service.remindUpdateLater()
        #expect(ackCount == 1)
        #expect(!service.debugHasPendingAcknowledgement)
    }

    @Test
    func cancelFiresHeldCancellationOnce()  {
        let (service, _) = makeService()
        var cancelCount = 0

        service.showUserInitiatedUpdateCheck(cancellation: { cancelCount += 1 })
        service.cancelUpdateOperation()
        service.cancelUpdateOperation()

        #expect(cancelCount == 1)
        #expect(service.updatePhase == .idle)
    }

    @Test
    func dismissUpdateInstallationDiscardsRepliesWithoutInvokingThem() {
        let (service, _) = makeService()
        var invoked = 0

        service.presentUpdateFound(version: "9.9", userInitiated: false) { _ in invoked += 1 }
        service.showReady { _ in invoked += 1 }
        service.dismissUpdateInstallation()

        #expect(invoked == 0)
        #expect(!service.debugHasUpdateReply)
        #expect(!service.debugHasReadyReply)
        #expect(service.updatePhase == .idle)
    }

    @Test
    func feedOverrideAcceptsHTTPSAndLoopbackOnly() {
        #expect(SparkleUpdaterDelegate.sanitizedOverride("https://updates.example.com/appcast.xml") != nil)
        #expect(SparkleUpdaterDelegate.sanitizedOverride("http://localhost:8000/appcast.xml") != nil)
        #expect(SparkleUpdaterDelegate.sanitizedOverride("http://127.0.0.1:8000/appcast.xml") != nil)
        #expect(SparkleUpdaterDelegate.sanitizedOverride("http://evil.example.com/appcast.xml") == nil)
        #expect(SparkleUpdaterDelegate.sanitizedOverride("file:///tmp/appcast.xml") == nil)
        #expect(SparkleUpdaterDelegate.sanitizedOverride("") == nil)
        #expect(SparkleUpdaterDelegate.sanitizedOverride(nil) == nil)
    }
}

private final class PanelRecorder {
    var presented: [Bool] = []
    var dismissCount = 0
}

private final class BundleToken {}

private enum TestUpdateError: Error, LocalizedError {
    case sample

    var errorDescription: String? { "sample failure" }
}
