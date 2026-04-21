import Foundation
import Testing
@testable import Wink

@Test @MainActor
func fallsBackToInfoPlistDefaultsWhenUpdaterConfigurationIsMissing() throws {
    let bundleURL = try makeBundleURL(infoDictionary: [
        "CFBundleIdentifier": "com.wink.tests.sparkle",
        "CFBundleName": "WinkTests",
        "CFBundlePackageType": "BNDL",
        "CFBundleShortVersionString": "0.3.0",
        "SUFeedURL": "",
        "SUPublicEDKey": "",
        "SUEnableAutomaticChecks": true,
        "SUAutomaticallyUpdate": true,
    ])
    defer { try? FileManager.default.removeItem(at: bundleURL) }

    guard let bundle = Bundle(url: bundleURL) else {
        throw SparkleUpdateServiceTestError.invalidBundle
    }

    let service = SparkleUpdateService(bundle: bundle)

    #expect(service.isConfigured == false)
    #expect(service.canCheckForUpdates == false)
    #expect(service.currentVersion == "0.3.0")
    #expect(service.automaticallyChecksForUpdates == true)
    #expect(service.automaticallyDownloadsUpdates == true)
}

private func makeBundleURL(infoDictionary: [String: Any]) throws -> URL {
    let bundleURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("bundle")
    let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
    let plistURL = contentsURL.appendingPathComponent("Info.plist")

    try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)

    guard NSDictionary(dictionary: infoDictionary).write(to: plistURL, atomically: true) else {
        throw SparkleUpdateServiceTestError.failedToWriteInfoPlist
    }

    return bundleURL
}

private enum SparkleUpdateServiceTestError: Error {
    case failedToWriteInfoPlist
    case invalidBundle
}
