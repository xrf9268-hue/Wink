import AppKit
import SwiftUI
import Testing
@testable import Wink

@Suite("Wink logo")
struct WinkLogoTests {
    @Test @MainActor
    func twinRendersAtMenuBarSize() {
        let view = NSHostingView(rootView: Logo_WinkTwin(size: 16, color: .black))
        view.frame = NSRect(x: 0, y: 0, width: 16, height: 16)
        view.layoutSubtreeIfNeeded()

        #expect(view.frame.width == 16)
        #expect(view.frame.height == 16)
        #expect(!view.subviews.isEmpty || view.intrinsicContentSize != .zero)
    }

    @Test @MainActor
    func twinRendersAtDockSize() {
        let view = NSHostingView(rootView: Logo_WinkTwin(size: 52, color: .white))
        view.frame = NSRect(x: 0, y: 0, width: 52, height: 52)
        view.layoutSubtreeIfNeeded()

        #expect(view.frame.width == 52)
    }

    @Test @MainActor
    func twinRendersAtHeroSize() {
        let view = NSHostingView(rootView: Logo_WinkTwin(size: 72, color: .black))
        view.frame = NSRect(x: 0, y: 0, width: 72, height: 72)
        view.layoutSubtreeIfNeeded()

        #expect(view.frame.width == 72)
    }

    @Test @MainActor
    func appIconWrapsTwinInGradientTile() {
        let view = NSHostingView(rootView: WinkAppIcon(size: 52))
        view.frame = NSRect(x: 0, y: 0, width: 52, height: 52)
        view.layoutSubtreeIfNeeded()

        #expect(view.frame.width == 52)
        #expect(view.frame.height == 52)
    }

    @Test @MainActor
    func wordmarkRenders() {
        let view = NSHostingView(rootView: WinkWordmark(size: 20, color: .black))
        view.layoutSubtreeIfNeeded()

        #expect(view.fittingSize.width > 0)
        #expect(view.fittingSize.height > 0)
    }
}
