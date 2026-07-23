import Foundation
import Testing
@testable import Wink

@Test @MainActor
func refreshIfNeededMergesRunningAppsAndSeedsRecentsWhenStoredRecentsAreMissing() async {
    let recorder = AppListProviderRecorder(now: Date(timeIntervalSinceReferenceDate: 100))
    let safariURL = URL(fileURLWithPath: "/Applications/Safari.app")
    let terminalURL = URL(fileURLWithPath: "/Applications/Utilities/Terminal.app")
    let provider = AppListProvider(client: .init(
        now: { recorder.now },
        scanInstalledApps: {
            recorder.scanCallCount += 1
            return [
                AppEntry(id: "com.apple.Safari", name: "Safari", url: safariURL)
            ]
        },
        runningApplications: {
            [
                .init(bundleIdentifier: "com.apple.Safari", localizedName: "Safari", bundleURL: safariURL, activationPolicy: .regular),
                .init(bundleIdentifier: "com.apple.Terminal", localizedName: "Terminal", bundleURL: terminalURL, activationPolicy: .regular),
                .init(bundleIdentifier: nil, localizedName: "Broken", bundleURL: nil, activationPolicy: .regular),
            ]
        },
        loadRecents: { nil },
        saveRecents: { recents in
            recorder.savedRecents.append(recents)
        },
        mainBundleIdentifier: { "com.example.Wink" }
    ))

    provider.refreshIfNeeded()
    await provider.waitForRefreshForTesting()

    #expect(recorder.scanCallCount == 1)
    #expect(provider.allApps.map(\.bundleIdentifier) == [
        "com.apple.Safari",
        "com.apple.Terminal",
    ])
    #expect(provider.recentBundleIDs == [
        "com.apple.Safari",
        "com.apple.Terminal",
    ])
}

@Test @MainActor
func refreshIfNeededSkipsRescanUntilSixtySecondsHaveElapsed() async {
    let recorder = AppListProviderRecorder(now: Date(timeIntervalSinceReferenceDate: 200))
    let provider = AppListProvider(client: .init(
        now: { recorder.now },
        scanInstalledApps: {
            recorder.scanCallCount += 1
            return []
        },
        runningApplications: { [] },
        loadRecents: { [] },
        saveRecents: { _ in },
        mainBundleIdentifier: { nil }
    ))

    provider.refreshIfNeeded()
    await provider.waitForRefreshForTesting()

    recorder.now = recorder.now.addingTimeInterval(30)
    provider.refreshIfNeeded()
    await provider.waitForRefreshForTesting()

    recorder.now = recorder.now.addingTimeInterval(31)
    provider.refreshIfNeeded()
    await provider.waitForRefreshForTesting()

    #expect(recorder.scanCallCount == 2)
}

@Test @MainActor
func forceRefreshAndWaitRescansWithinCacheWindow() async {
    let recorder = AppListProviderRecorder(now: Date(timeIntervalSinceReferenceDate: 250))
    let provider = AppListProvider(client: .init(
        now: { recorder.now },
        scanInstalledApps: {
            recorder.scanCallCount += 1
            return []
        },
        runningApplications: { [] },
        loadRecents: { [] },
        saveRecents: { _ in },
        mainBundleIdentifier: { nil }
    ))

    provider.refreshIfNeeded()
    await provider.waitForRefreshForTesting()

    recorder.now = recorder.now.addingTimeInterval(10)
    await provider.forceRefreshAndWait()

    #expect(recorder.scanCallCount == 2)
}

@Test @MainActor
func noteRecentAppCapsPersistedRecentsAtTenEntries() {
    let recorder = AppListProviderRecorder(now: Date())
    let provider = AppListProvider(client: .init(
        now: { recorder.now },
        scanInstalledApps: { [] },
        runningApplications: { [] },
        loadRecents: { [] },
        saveRecents: { recents in
            recorder.savedRecents.append(recents)
        },
        mainBundleIdentifier: { nil }
    ))

    for index in 0..<12 {
        provider.noteRecentApp(bundleIdentifier: "com.example.\(index)")
    }

    #expect(provider.recentBundleIDs.count == 10)
    #expect(provider.recentBundleIDs.first == "com.example.11")
    #expect(provider.recentBundleIDs.last == "com.example.2")
    #expect(recorder.savedRecents.last?.count == 10)
}

@Test @MainActor
func recentAppsResolvesAgainstAllAppsCacheAndSkipsStaleBundleIDs() async {
    let recorder = AppListProviderRecorder(now: Date(timeIntervalSinceReferenceDate: 300))
    let safariURL = URL(fileURLWithPath: "/Applications/Safari.app")
    let finderURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
    let provider = AppListProvider(client: .init(
        now: { recorder.now },
        scanInstalledApps: {
            recorder.scanCallCount += 1
            return [
                AppEntry(id: "com.apple.Safari", name: "Safari", url: safariURL),
                AppEntry(id: "com.apple.Finder", name: "Finder", url: finderURL),
            ]
        },
        runningApplications: { [] },
        loadRecents: { ["com.apple.Safari", "com.apple.Finder", "com.example.missing"] },
        saveRecents: { _ in },
        mainBundleIdentifier: { nil }
    ))

    provider.refreshIfNeeded()
    await provider.waitForRefreshForTesting()

    let resolved = provider.recentApps.map(\.bundleIdentifier)
    #expect(resolved == ["com.apple.Safari", "com.apple.Finder"])
}

@Test @MainActor
func appLookupHelpersSupportBundleIDAndExactNameMatching() async {
    let recorder = AppListProviderRecorder(now: Date(timeIntervalSinceReferenceDate: 400))
    let safariURL = URL(fileURLWithPath: "/Applications/Safari.app")
    let notesOneURL = URL(fileURLWithPath: "/Applications/Notes One.app")
    let notesTwoURL = URL(fileURLWithPath: "/Applications/Notes Two.app")
    let provider = AppListProvider(client: .init(
        now: { recorder.now },
        scanInstalledApps: {
            recorder.scanCallCount += 1
            return [
                AppEntry(id: "com.apple.Safari", name: "Safari", url: safariURL),
                AppEntry(id: "com.example.notes.one", name: "Notes", url: notesOneURL),
                AppEntry(id: "com.example.notes.two", name: "Notes", url: notesTwoURL),
            ]
        },
        runningApplications: { [] },
        loadRecents: { [] },
        saveRecents: { _ in },
        mainBundleIdentifier: { nil }
    ))

    provider.refreshIfNeeded()
    await provider.waitForRefreshForTesting()

    #expect(provider.app(for: "com.apple.Safari")?.name == "Safari")
    #expect(provider.isInstalled(bundleIdentifier: "com.apple.Safari") == true)
    #expect(provider.isInstalled(bundleIdentifier: "com.example.missing") == false)
    #expect(provider.apps(named: "notes").map(\.bundleIdentifier).sorted() == [
        "com.example.notes.one",
        "com.example.notes.two",
    ].sorted())
}

@Test @MainActor
func refreshExcludesNonRegularActivationPolicyRunningApps() async {
    let recorder = AppListProviderRecorder(now: Date(timeIntervalSinceReferenceDate: 500))
    let safariURL = URL(fileURLWithPath: "/Applications/Safari.app")
    let loginwindowURL = URL(fileURLWithPath: "/System/Library/CoreServices/loginwindow.app")
    let viewBridgeURL = URL(fileURLWithPath: "/System/Library/ViewBridgeAuxiliary.app")
    let provider = AppListProvider(client: .init(
        now: { recorder.now },
        scanInstalledApps: {
            recorder.scanCallCount += 1
            return []
        },
        runningApplications: {
            [
                .init(bundleIdentifier: "com.apple.Safari", localizedName: "Safari", bundleURL: safariURL, activationPolicy: .regular),
                .init(bundleIdentifier: "com.apple.loginwindow", localizedName: "loginwindow", bundleURL: loginwindowURL, activationPolicy: .accessory),
                .init(bundleIdentifier: "com.apple.ViewBridgeAuxiliary", localizedName: "ViewBridgeAuxiliary", bundleURL: viewBridgeURL, activationPolicy: .prohibited),
            ]
        },
        loadRecents: { nil },
        saveRecents: { _ in },
        mainBundleIdentifier: { nil }
    ))

    provider.refreshIfNeeded()
    await provider.waitForRefreshForTesting()

    #expect(provider.allApps.map(\.bundleIdentifier) == ["com.apple.Safari"])
}

@Test @MainActor
func refreshDedupesSharedLocalizedNameToTheRegularActivationPolicyApp() async {
    // Mirrors #384's WeChat report: com.tencent.xinWeChat (.regular) and its
    // embedded helper com.tencent.flue.WeChatAppEx (.accessory) both report
    // localizedName "WeChat" — only the .regular one should surface.
    let recorder = AppListProviderRecorder(now: Date(timeIntervalSinceReferenceDate: 550))
    let weChatURL = URL(fileURLWithPath: "/Applications/WeChat.app")
    let weChatHelperURL = URL(fileURLWithPath: "/Applications/WeChat.app/Contents/Helpers/WeChatAppEx.app")
    let provider = AppListProvider(client: .init(
        now: { recorder.now },
        scanInstalledApps: {
            recorder.scanCallCount += 1
            return []
        },
        runningApplications: {
            [
                .init(bundleIdentifier: "com.tencent.xinWeChat", localizedName: "WeChat", bundleURL: weChatURL, activationPolicy: .regular),
                .init(bundleIdentifier: "com.tencent.flue.WeChatAppEx", localizedName: "WeChat", bundleURL: weChatHelperURL, activationPolicy: .accessory),
            ]
        },
        loadRecents: { nil },
        saveRecents: { _ in },
        mainBundleIdentifier: { nil }
    ))

    provider.refreshIfNeeded()
    await provider.waitForRefreshForTesting()

    #expect(provider.allApps.map(\.bundleIdentifier) == ["com.tencent.xinWeChat"])
    #expect(provider.allApps.filter { $0.name == "WeChat" }.count == 1)
}

@Test @MainActor
func recentsSeedingExcludesNonRegularActivationPolicyApps() async {
    let recorder = AppListProviderRecorder(now: Date(timeIntervalSinceReferenceDate: 600))
    let safariURL = URL(fileURLWithPath: "/Applications/Safari.app")
    let windowManagerURL = URL(fileURLWithPath: "/System/Library/CoreServices/WindowManager.app")
    let provider = AppListProvider(client: .init(
        now: { recorder.now },
        scanInstalledApps: {
            recorder.scanCallCount += 1
            return []
        },
        runningApplications: {
            [
                .init(bundleIdentifier: "com.apple.Safari", localizedName: "Safari", bundleURL: safariURL, activationPolicy: .regular),
                .init(bundleIdentifier: "com.apple.WindowManager", localizedName: "WindowManager", bundleURL: windowManagerURL, activationPolicy: .accessory),
            ]
        },
        loadRecents: { nil },
        saveRecents: { _ in },
        mainBundleIdentifier: { nil }
    ))

    provider.refreshIfNeeded()
    await provider.waitForRefreshForTesting()

    #expect(provider.recentBundleIDs == ["com.apple.Safari"])
}

@Test @MainActor
func recentsSanitizationDropsSystemAgentsButKeepsNotRunningOnes() async {
    let recorder = AppListProviderRecorder(now: Date(timeIntervalSinceReferenceDate: 650))
    let loginwindowURL = URL(fileURLWithPath: "/System/Library/CoreServices/loginwindow.app")
    let provider = AppListProvider(client: .init(
        now: { recorder.now },
        scanInstalledApps: {
            recorder.scanCallCount += 1
            // loginwindow is outside every scan root, so it resolves in
            // neither the scan nor allAppsByID — the second prong of the
            // sanitization condition.
            return []
        },
        runningApplications: {
            // loginwindow is currently running as an .accessory agent;
            // com.example.notRunning isn't present at all in this snapshot.
            [
                .init(bundleIdentifier: "com.apple.loginwindow", localizedName: "loginwindow", bundleURL: loginwindowURL, activationPolicy: .accessory),
            ]
        },
        loadRecents: {
            ["com.apple.loginwindow", "com.example.notRunning"]
        },
        saveRecents: { _ in },
        mainBundleIdentifier: { nil }
    ))

    provider.refreshIfNeeded()
    await provider.waitForRefreshForTesting()

    #expect(provider.recentBundleIDs == ["com.example.notRunning"])
}

@Test @MainActor
func recentsSanitizationKeepsInstalledAccessoryAppEvenWhileCurrentlyRunning() async {
    // Regression for a false positive found in review: a legitimate
    // menu-bar-only app installed under a scan root (so it resolves in
    // allAppsByID) must survive sanitization even though it currently runs
    // as .accessory — Wink's toggle engine explicitly supports windowless
    // .accessory targets (docs/architecture.md:405), and this is exactly
    // the kind of app the Settings picker could have put into recents.
    let recorder = AppListProviderRecorder(now: Date(timeIntervalSinceReferenceDate: 700))
    let menuBarAppURL = URL(fileURLWithPath: "/Applications/MenuBarApp.app")
    let provider = AppListProvider(client: .init(
        now: { recorder.now },
        scanInstalledApps: {
            recorder.scanCallCount += 1
            return [
                AppEntry(id: "com.example.menubarapp", name: "MenuBarApp", url: menuBarAppURL),
            ]
        },
        runningApplications: {
            [
                .init(bundleIdentifier: "com.example.menubarapp", localizedName: "MenuBarApp", bundleURL: menuBarAppURL, activationPolicy: .accessory),
            ]
        },
        loadRecents: {
            ["com.example.menubarapp"]
        },
        saveRecents: { _ in },
        mainBundleIdentifier: { nil }
    ))

    provider.refreshIfNeeded()
    await provider.waitForRefreshForTesting()

    #expect(provider.recentBundleIDs == ["com.example.menubarapp"])
    #expect(provider.recentApps.map(\.bundleIdentifier) == ["com.example.menubarapp"])
}

private final class AppListProviderRecorder: @unchecked Sendable {
    var now: Date
    var scanCallCount = 0
    var savedRecents: [[String]] = []

    init(now: Date) {
        self.now = now
    }
}
