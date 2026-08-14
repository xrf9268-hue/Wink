import Foundation
import Testing
import WinkIntents
@testable import Wink

@Suite("Safe wink URL command handling")
@MainActor
struct WinkURLCommandHandlerTests {
    @Test
    func toggleAndFocusUseTheirExactApplicationSemantics() {
        var performed: [(shortcut: AppShortcut, bypassCooldown: Bool)] = []
        let handler = WinkURLCommandHandler(client: .init(
            applicationURL: { bundleIdentifier in
                bundleIdentifier == "com.apple.Safari"
                    ? URL(fileURLWithPath: "/Applications/Safari.app")
                    : nil
            },
            performApplicationAction: { shortcut, bypassCooldown in
                performed.append((shortcut, bypassCooldown))
                return true
            },
            executeSharedAction: { _, _ in },
            log: { _ in }
        ))

        handler.handle([
            "wink://toggle?bundle=com.apple.Safari",
            "wink://focus?bundle=com.apple.Safari",
        ])

        #expect(performed.count == 2)
        #expect(performed[0].shortcut.appName == "Safari")
        #expect(performed[0].shortcut.bundleIdentifier == "com.apple.Safari")
        #expect(performed[0].shortcut.frontmostBehaviorOverride == nil)
        #expect(performed[0].bypassCooldown == false)
        #expect(performed[1].shortcut.appName == "Safari")
        #expect(performed[1].shortcut.bundleIdentifier == "com.apple.Safari")
        #expect(performed[1].shortcut.frontmostBehaviorOverride == .focus)
        #expect(performed[1].bypassCooldown == true)
    }

    @Test
    func installedApplicationCanonicalizesBundleIdentifierBeforeFocusDispatch() {
        var performed: [AppShortcut] = []
        var logs: [String] = []
        let handler = WinkURLCommandHandler(client: .init(
            applicationURL: { bundleIdentifier in
                bundleIdentifier == "COM.APPLE.FINDER"
                    ? URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
                    : nil
            },
            canonicalBundleIdentifier: { _ in "com.apple.finder" },
            performApplicationAction: { shortcut, _ in
                performed.append(shortcut)
                return true
            },
            executeSharedAction: { _, _ in },
            log: { logs.append($0) }
        ))

        handler.handle(["wink://focus?bundle=COM.APPLE.FINDER"])

        #expect(performed.map(\.bundleIdentifier) == ["com.apple.finder"])
        #expect(performed.first?.frontmostBehaviorOverride == .focus)
        #expect(logs == ["URL: accepted command=focus bundle=com.apple.finder"])
    }

    @Test
    func unavailableApplicationsDoNotReachTheActivationPipeline() {
        var applicationActions = 0
        var sharedActions = 0
        var logs: [String] = []
        let handler = WinkURLCommandHandler(client: .init(
            applicationURL: { _ in nil },
            performApplicationAction: { _, _ in
                applicationActions += 1
                return true
            },
            executeSharedAction: { _, _ in sharedActions += 1 },
            log: { logs.append($0) }
        ))

        handler.handle([
            "wink://focus?bundle=com.example.Missing",
            "wink://toggle?bundle=com.example.Missing",
        ])

        #expect(applicationActions == 0)
        #expect(sharedActions == 0)
        #expect(logs.count == 2)
        #expect(logs.allSatisfy { $0.hasPrefix("URL: ignored unavailable command=") })
    }

    @Test
    func searchAndSettingsAreHandledOncePerDeliveryBatch() {
        var actions: [WinkAction] = []
        var policies: [WinkActionExecutor.SettingsPresentationPolicy] = []
        var logs: [String] = []
        let handler = WinkURLCommandHandler(client: .init(
            applicationURL: { _ in nil },
            performApplicationAction: { _, _ in false },
            executeSharedAction: { action, policy in
                actions.append(action)
                policies.append(policy)
            },
            log: { logs.append($0) }
        ))

        handler.handle([
            "wink://search",
            "wink://search",
            "wink://open-settings?tab=insights",
            "wink://open-settings?tab=general",
        ])

        #expect(actions == [.showSearchPalette, .openSettings(.insights)])
        #expect(policies == [.requireReady, .allowDeferred])
        #expect(logs.contains("URL: ignored duplicate_in_batch command=search"))
        #expect(logs.contains("URL: ignored duplicate_in_batch command=open-settings"))
    }

    @Test
    func legacyPauseAndResumeUseTheSharedIdempotentExecutor() {
        var actions: [WinkAction] = []
        var policies: [WinkActionExecutor.SettingsPresentationPolicy] = []
        let handler = WinkURLCommandHandler(client: .init(
            applicationURL: { _ in nil },
            performApplicationAction: { _, _ in false },
            executeSharedAction: { action, policy in
                actions.append(action)
                policies.append(policy)
            },
            log: { _ in }
        ))

        handler.handle([
            "wink://pause",
            "wink://resume",
        ])

        #expect(actions == [.pause, .resume])
        #expect(policies == [.requireReady, .requireReady])
    }

    @Test
    func rejectedInputLogsOnlyABoundedReason() {
        var sideEffects = 0
        var logs: [String] = []
        let handler = WinkURLCommandHandler(client: .init(
            applicationURL: { _ in
                sideEffects += 1
                return nil
            },
            performApplicationAction: { _, _ in
                sideEffects += 1
                return false
            },
            executeSharedAction: { _, _ in sideEffects += 1 },
            log: { logs.append($0) }
        ))
        let secret = "do-not-log-this-secret"

        handler.handle([
            "wink://focus?bundle=com.apple.Safari&token=\(secret)",
        ])

        #expect(sideEffects == 0)
        #expect(logs == ["URL: ignored reason=unknown_parameter"])
        #expect(!logs.joined().contains(secret))
        #expect(logs[0].utf8.count < 80)
    }

    @Test
    func rawUnicodeCommandAliasesAreRejectedBeforeAnySideEffect() {
        var sideEffects = 0
        var logs: [String] = []
        let handler = WinkURLCommandHandler(client: .init(
            applicationURL: { _ in
                sideEffects += 1
                return nil
            },
            performApplicationAction: { _, _ in
                sideEffects += 1
                return false
            },
            executeSharedAction: { _, _ in sideEffects += 1 },
            log: { logs.append($0) }
        ))

        handler.handle(["wink://ＰＡＵＳＥ", "wink://open－settings?tab=insights"])

        #expect(sideEffects == 0)
        #expect(logs == [
            "URL: ignored reason=non_ascii_authority",
            "URL: ignored reason=non_ascii_authority",
        ])
    }
}
