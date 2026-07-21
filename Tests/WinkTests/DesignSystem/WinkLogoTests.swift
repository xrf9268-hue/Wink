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
    func twinUsesCircleSubtractionCrescentGeometryFromDesign() throws {
        let bitmap = try renderBitmap(
            Logo_WinkTwin(size: 64, color: .black),
            size: NSSize(width: 64, height: 64)
        )

        #expect(alpha(atViewBoxX: 4, y: 16, in: bitmap) > 0.75)
        #expect(alpha(atViewBoxX: 15, y: 13, in: bitmap) < 0.15)
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
    func appIconUsesInkNavyAnchorTile() throws {
        let bitmap = try renderBitmap(
            WinkAppIcon(size: 52),
            size: NSSize(width: 52, height: 52)
        )
        let color = try #require(bitmap.colorAt(x: 12, y: 12))

        // Ink-navy tile: blue channel leads and the sample stays dark —
        // distinguishes the amber-rebrand tile from the old violet gradient
        // (red-led) without pinning exact anti-aliased pixel values.
        #expect(color.blueComponent > color.redComponent)
        #expect(color.blueComponent < 0.5)
    }

    @Test
    func appIconSVGUsesLatestDesignGradientAndTwinGeometry() throws {
        let svg = try String(
            contentsOf: repoRoot.appending(path: "Sources/Wink/Resources/AppIcon.svg"),
            encoding: .utf8
        )

        #expect(svg.contains("#1E2638"))
        #expect(svg.contains("#10141E"))
        #expect(svg.contains("#0A0D14"))
        #expect(svg.contains("#FFB454"))
        #expect(svg.contains("M12 7 a9 9 0 1 0 0 18"))
        #expect(!svg.contains("#8A5BE3"))
        #expect(!svg.contains("#5E3FC7"))
        #expect(!svg.contains("#4A7BE8"))
    }

    @Test
    func dmgBackgroundUsesLatestLogoPalette() throws {
        let svg = try String(
            contentsOf: repoRoot.appending(path: "assets/dmg/wink-dmg-background.svg"),
            encoding: .utf8
        )

        #expect(svg.contains("#E08A00"))
        #expect(svg.contains("#A8620A"))
        #expect(svg.contains("#1E2638"))
        #expect(!svg.contains("#8A5BE3"))
        #expect(!svg.contains("#5E3FC7"))
        #expect(!svg.contains("#4A7BE8"))
    }

    @Test
    func dmgBackgroundUsesEditorialLightInstallerLayout() throws {
        let svg = try String(
            contentsOf: repoRoot.appending(path: "assets/dmg/wink-dmg-background.svg"),
            encoding: .utf8
        )

        #expect(svg.contains("#F5F1EA"))
        #expect(svg.contains("#ECE6D8"))
        #expect(svg.contains("INSTALL"))
        #expect(svg.contains("Drag Wink to your"))
        #expect(svg.contains("Applications folder."))
        #expect(svg.contains("Wink lives in your menu bar. Always a wink away."))
        #expect(svg.contains("opacity=\"0.08\""))
        #expect(svg.contains("scale(8.75)"))
        #expect(svg.contains("viewBox=\"0 0 680 429\""))
        #expect(!svg.contains("id=\"toolbarStrip\""))
        #expect(!svg.contains("Drag Wink to Applications"))
        #expect(!svg.contains("Menu bar app switching"))
    }

    @Test
    func packageDmgUsesFinderAccurateLabelsAndBottomAnchorPositions() throws {
        let script = try String(
            contentsOf: repoRoot.appending(path: "scripts/package-dmg.sh"),
            encoding: .utf8
        )

        #expect(script.contains("WINDOW_WIDTH=680"))
        #expect(script.contains("WINDOW_HEIGHT=460"))
        #expect(script.contains("ICON_SIZE=96"))
        #expect(script.contains("TEXT_SIZE=11"))
        #expect(script.contains("APP_ICON_X=122"))
        #expect(script.contains("APP_ICON_Y=300"))
        #expect(script.contains("APPLICATIONS_X=558"))
        #expect(script.contains("APPLICATIONS_Y=300"))
        #expect(script.contains("set toolbar visible to false"))
        #expect(script.contains("set sidebar width to 0"))
        #expect(script.contains("APPLICATIONS_ICON_SOURCE="))
        #expect(script.contains("make new alias file to POSIX file \"/Applications\""))
        #expect(script.contains("Rez -append"))
        #expect(script.contains("SetFile -a C"))
        #expect(!script.contains("ln -s /Applications"))
        #expect(!script.contains("WINDOW_WIDTH=640"))
        #expect(!script.contains("WINDOW_HEIGHT=440"))
        #expect(!script.contains("ICON_SIZE=104"))
        #expect(!script.contains("TEXT_SIZE=13"))
        #expect(!script.contains("APP_ICON_Y=214"))
        #expect(!script.contains("APPLICATIONS_Y=214"))
    }

    @Test @MainActor
    func wordmarkRenders() {
        let view = NSHostingView(rootView: WinkWordmark(size: 20, color: .black))
        view.layoutSubtreeIfNeeded()

        #expect(view.fittingSize.width > 0)
        #expect(view.fittingSize.height > 0)
    }
}

@MainActor
private func renderBitmap<Content: View>(
    _ view: Content,
    size: NSSize
) throws -> NSBitmapImageRep {
    let hostingView = NSHostingView(rootView: view)
    hostingView.frame = NSRect(origin: .zero, size: size)
    hostingView.layoutSubtreeIfNeeded()

    let representation = try #require(
        hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
    )
    hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
    return representation
}

private func alpha(
    atViewBoxX x: Int,
    y: Int,
    in bitmap: NSBitmapImageRep
) -> CGFloat {
    let pixelX = min(bitmap.pixelsWide - 1, max(0, x * bitmap.pixelsWide / 32))
    let pixelY = min(bitmap.pixelsHigh - 1, max(0, y * bitmap.pixelsHigh / 32))
    return bitmap.colorAt(x: pixelX, y: pixelY)?.alphaComponent ?? 0
}

private let repoRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
