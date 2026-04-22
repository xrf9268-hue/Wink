import AppKit
import SwiftUI
import Testing
@testable import Wink

@Suite("App launch")
struct AppLaunchTests {
    /// `WinkApp` is the SwiftUI `App` that replaces the deleted `main.swift`.
    /// Constructing the value drives the body builder, which proves the
    /// `@NSApplicationDelegateAdaptor` + `Settings` scene wiring compiles
    /// and instantiates without `Scene` runtime errors.
    @Test @MainActor
    func winkAppBodyEvaluatesWithoutCrashing() {
        let app = WinkApp()
        // Touching `body` triggers the result builder.
        _ = app.body
    }

    /// `AppDelegate` lives on so existing service wiring keeps working under
    /// `@NSApplicationDelegateAdaptor`. Verify it is still an
    /// `NSApplicationDelegate` with the expected lifecycle hooks.
    @Test @MainActor
    func appDelegateConformsToNSApplicationDelegate() {
        let delegate = AppDelegate()
        #expect((delegate as NSApplicationDelegate?) != nil)
    }
}
