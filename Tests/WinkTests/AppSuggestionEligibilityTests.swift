import AppKit
import Foundation
import Testing
@testable import Wink

// MARK: - Fixtures

/// Builds a throwaway on-disk .app skeleton (Contents/Info.plist only) so
/// the plist-proxy path of `isSuggestable` runs against a real Bundle read.
/// Unique per call: Bundle caches instances by path.
private func makeAppFixture(
    named name: String,
    infoPlist: [String: Any]?
) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("wink-eligibility-\(UUID().uuidString)")
    let appURL = root.appendingPathComponent("\(name).app")
    let contents = appURL.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    if let infoPlist {
        let data = try PropertyListSerialization.data(
            fromPropertyList: infoPlist,
            format: .xml,
            options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }
    return appURL
}

// MARK: - StandardApplicationDirectories

@Suite("StandardApplicationDirectories containment")
struct StandardApplicationDirectoriesTests {
    @Test
    func acceptsAppsInsideEveryStandardRoot() {
        #expect(StandardApplicationDirectories.contains(
            URL(fileURLWithPath: "/Applications/Safari.app")))
        #expect(StandardApplicationDirectories.contains(
            URL(fileURLWithPath: "/Applications/Utilities/Some Tool.app")))
        #expect(StandardApplicationDirectories.contains(
            URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")))
        #expect(StandardApplicationDirectories.contains(
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications/Local.app")))
    }

    @Test
    func rejectsLookalikePrefixesNestedHelpersAndSystemPaths() {
        // String-prefix lookalike, not the real root.
        #expect(!StandardApplicationDirectories.contains(
            URL(fileURLWithPath: "/ApplicationsFake/Evil.app")))
        // Embedded helper inside another bundle: the installed-app scan
        // never descends into .app bundles, so neither may this check.
        #expect(!StandardApplicationDirectories.contains(
            URL(fileURLWithPath: "/Applications/Teams.app/Contents/Frameworks/Helper.app")))
        // The motivating case: the Accessibility auth-warning dialog.
        #expect(!StandardApplicationDirectories.contains(
            URL(fileURLWithPath: "/System/Library/PrivateFrameworks/UniversalAccess.framework/Versions/A/Resources/universalAccessAuthWarn.app")))
        // Not an .app bundle at all.
        #expect(!StandardApplicationDirectories.contains(
            URL(fileURLWithPath: "/Applications/readme.txt")))
        #expect(!StandardApplicationDirectories.contains(
            URL(fileURLWithPath: "/Applications")))
    }
}

// MARK: - AppSuggestionEligibility

@Suite("AppSuggestionEligibility record-time gate")
struct AppSuggestionEligibilityRecordTests {
    @Test
    func regularAppsAlwaysRecord() {
        #expect(AppSuggestionEligibility.shouldRecordActivation(
            activationPolicy: .regular, bundleURL: nil))
        #expect(AppSuggestionEligibility.shouldRecordActivation(
            activationPolicy: .regular,
            bundleURL: URL(fileURLWithPath: "/opt/somewhere/Odd.app")))
    }

    @Test
    func nonRegularAppsRecordOnlyWhenInstalledInStandardRoots() {
        // A real app the user runs menu-bar-only / with a hidden Dock icon.
        #expect(AppSuggestionEligibility.shouldRecordActivation(
            activationPolicy: .accessory,
            bundleURL: URL(fileURLWithPath: "/Applications/Ice.app")))
        // System dialog outside every root — the reported bug.
        #expect(!AppSuggestionEligibility.shouldRecordActivation(
            activationPolicy: .accessory,
            bundleURL: URL(fileURLWithPath: "/System/Library/PrivateFrameworks/UniversalAccess.framework/Versions/A/Resources/universalAccessAuthWarn.app")))
        #expect(!AppSuggestionEligibility.shouldRecordActivation(
            activationPolicy: .accessory, bundleURL: nil))
        #expect(!AppSuggestionEligibility.shouldRecordActivation(
            activationPolicy: .prohibited,
            bundleURL: URL(fileURLWithPath: "/System/Library/CoreServices/loginwindow.app")))
    }
}

@Suite("AppSuggestionEligibility query-time gate")
struct AppSuggestionEligibilityQueryTests {
    @Test
    func standardLocationShortCircuitsWithoutTouchingDisk() {
        // Nonexistent on purpose: the standard-dir branch is pure path logic.
        #expect(AppSuggestionEligibility.isSuggestable(
            appURL: URL(fileURLWithPath: "/Applications/DoesNotExist-\(UUID().uuidString).app")))
    }

    @Test
    func backgroundUIMarkersDisqualifyOutsideStandardRoots() throws {
        // universalAccessAuthWarn ships the numeric form; cover the bool and
        // string spellings too — all three appear in the wild.
        for marker: [String: Any] in [
            ["LSUIElement": true],
            ["LSUIElement": 1],
            ["LSUIElement": "1"],
            ["LSBackgroundOnly": true],
        ] {
            let fixture = try makeAppFixture(named: "AgentFixture", infoPlist: marker)
            #expect(!AppSuggestionEligibility.isSuggestable(appURL: fixture))
        }
    }

    @Test
    func plainAppsOutsideStandardRootsStaySuggestable() throws {
        let regular = try makeAppFixture(
            named: "RegularFixture",
            infoPlist: ["CFBundleIdentifier": "com.example.regular"]
        )
        #expect(AppSuggestionEligibility.isSuggestable(appURL: regular))

        let markerOff = try makeAppFixture(
            named: "MarkerOffFixture",
            infoPlist: ["LSUIElement": false]
        )
        #expect(AppSuggestionEligibility.isSuggestable(appURL: markerOff))

        // Unreadable Info.plist keeps the app, mirroring the record-time
        // default of trusting .regular.
        let bare = try makeAppFixture(named: "BareFixture", infoPlist: nil)
        #expect(AppSuggestionEligibility.isSuggestable(appURL: bare))
    }
}

// MARK: - AppActivationRecorder

@Suite("AppActivationRecorder policy gate")
@MainActor
struct AppActivationRecorderTests {
    @Test
    func recordsRegularAppsWhenEnabled() {
        var recorded: [String] = []
        let recorder = AppActivationRecorder(onActivation: { recorded.append($0) })
        recorder.setEnabled(true)

        recorder.handleActivation(
            bundleIdentifier: "com.example.editor",
            activationPolicy: .regular,
            bundleURL: nil
        )

        #expect(recorded == ["com.example.editor"])
    }

    @Test
    func dropsSystemDialogsButKeepsInstalledAccessoryApps() {
        var recorded: [String] = []
        let recorder = AppActivationRecorder(onActivation: { recorded.append($0) })
        recorder.setEnabled(true)

        recorder.handleActivation(
            bundleIdentifier: "com.apple.accessibility.universalAccessAuthWarn",
            activationPolicy: .accessory,
            bundleURL: URL(fileURLWithPath: "/System/Library/PrivateFrameworks/UniversalAccess.framework/Versions/A/Resources/universalAccessAuthWarn.app")
        )
        recorder.handleActivation(
            bundleIdentifier: "com.example.menubar",
            activationPolicy: .accessory,
            bundleURL: URL(fileURLWithPath: "/Applications/MenuBarThing.app")
        )

        #expect(recorded == ["com.example.menubar"])
    }

    @Test
    func staysSilentWhenDisabledOrWithoutIdentity() {
        var recorded: [String] = []
        let recorder = AppActivationRecorder(onActivation: { recorded.append($0) })

        recorder.handleActivation(
            bundleIdentifier: "com.example.editor",
            activationPolicy: .regular,
            bundleURL: nil
        )
        recorder.setEnabled(true)
        recorder.handleActivation(
            bundleIdentifier: nil,
            activationPolicy: .regular,
            bundleURL: nil
        )

        #expect(recorded.isEmpty)
    }
}
