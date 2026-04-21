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
                .init(bundleIdentifier: "com.apple.Safari", localizedName: "Safari", bundleURL: safariURL),
                .init(bundleIdentifier: "com.apple.Terminal", localizedName: "Terminal", bundleURL: terminalURL),
                .init(bundleIdentifier: nil, localizedName: "Broken", bundleURL: nil),
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

private final class AppListProviderRecorder: @unchecked Sendable {
    var now: Date
    var scanCallCount = 0
    var savedRecents: [[String]] = []

    init(now: Date) {
        self.now = now
    }
}
