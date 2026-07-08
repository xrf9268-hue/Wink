import Foundation
import Sparkle

@MainActor
final class SparkleUpdateService: UpdateServicing {
    private let bundle: Bundle
    private let updaterController: SPUStandardUpdaterController?

    init(bundle: Bundle = .main) {
        self.bundle = bundle

        if Self.hasValidConfiguration(bundle: bundle) {
            self.updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
        } else {
            self.updaterController = nil
        }
    }

    var isConfigured: Bool {
        updaterController != nil
    }

    var canCheckForUpdates: Bool {
        updaterController?.updater.canCheckForUpdates ?? false
    }

    var currentVersion: String {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    var automaticallyChecksForUpdates: Bool {
        get {
            updaterController?.updater.automaticallyChecksForUpdates
                ?? Self.boolValue(forInfoDictionaryKey: "SUEnableAutomaticChecks", bundle: bundle, default: true)
        }
        set {
            updaterController?.updater.automaticallyChecksForUpdates = newValue
        }
    }

    var automaticallyDownloadsUpdates: Bool {
        get {
            updaterController?.updater.automaticallyDownloadsUpdates
                ?? Self.boolValue(forInfoDictionaryKey: "SUAutomaticallyUpdate", bundle: bundle, default: true)
        }
        set {
            updaterController?.updater.automaticallyDownloadsUpdates = newValue
        }
    }

    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    private static func hasValidConfiguration(bundle: Bundle) -> Bool {
        hasNonEmptyString("SUFeedURL", bundle: bundle) &&
        hasNonEmptyString("SUPublicEDKey", bundle: bundle)
    }

    private static func hasNonEmptyString(_ key: String, bundle: Bundle) -> Bool {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String else {
            return false
        }

        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func boolValue(
        forInfoDictionaryKey key: String,
        bundle: Bundle,
        default defaultValue: Bool
    ) -> Bool {
        if let value = bundle.object(forInfoDictionaryKey: key) as? Bool {
            return value
        }

        if let value = bundle.object(forInfoDictionaryKey: key) as? NSNumber {
            return value.boolValue
        }

        return defaultValue
    }
}
