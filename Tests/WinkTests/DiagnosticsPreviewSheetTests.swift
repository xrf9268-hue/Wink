import AppKit
import SwiftUI
import Testing
@testable import Wink

/// #461 finding 1: the preview sheet used to show only each entry's name,
/// byte count, and summary — never `entry.contents` — which contradicted the
/// Diagnostics card's promise that a user can check the contents before
/// saving or sharing them. These tests cover the two things that make that
/// true: `displayedEntry` never leaves the contents pane pointing at nothing,
/// and the rendered sheet actually adds a second scrollable region for it.
@Suite("Diagnostics preview sheet")
struct DiagnosticsPreviewSheetTests {
    private func package(logCount: Int = 1) -> DiagnosticsPackage {
        var entries = [
            DiagnosticsPackage.Entry(
                name: "report.md",
                summary: "Wink and macOS versions.",
                contents: "# Wink diagnostics\nreport body"
            ),
        ]
        for index in 0..<logCount {
            entries.append(
                DiagnosticsPackage.Entry(
                    name: index == 0 ? "debug.log" : "debug.log.1",
                    summary: "Recent Wink activity.",
                    contents: "log-\(index)-marker line"
                )
            )
        }
        return DiagnosticsPackage(entries: entries)
    }

    // MARK: - Selection fallback (pure logic)

    @Test
    func displayedEntryDefaultsToTheFirstEntryWhenNothingIsSelected() {
        let package = package(logCount: 2)
        let entry = DiagnosticsPreviewSheet.displayedEntry(for: nil, in: package)
        #expect(entry?.name == package.entries.first?.name)
    }

    @Test
    func displayedEntryResolvesAMatchingSelection() {
        let package = package(logCount: 2)
        let target = package.entries[2]
        let entry = DiagnosticsPreviewSheet.displayedEntry(for: target.id, in: package)
        #expect(entry?.id == target.id)
        #expect(entry?.contents == target.contents)
    }

    @Test
    func displayedEntryFallsBackToTheFirstEntryWhenTheSelectionNoLongerExists() {
        // `prepareExport` rebuilds `preview` fresh on every call; a selection
        // id left over from a previous package (or one that just never
        // matched) must not leave the contents pane showing nothing.
        let package = package(logCount: 1)
        let entry = DiagnosticsPreviewSheet.displayedEntry(for: "does-not-exist.log", in: package)
        #expect(entry?.name == package.entries.first?.name)
    }

    // MARK: - Rendering (structural)

    @Test @MainActor
    func theContentsPaneAddsItsOwnScrollableRegion() {
        let hostingView = makeHostingView(
            DiagnosticsPreviewSheet(package: package(logCount: 2), diagnostics: makeInertDiagnosticsState())
                .winkChromeRoot(),
            size: NSSize(width: 600, height: 760)
        )

        // The entries list is already one NSScrollView (SwiftUI `List` on
        // macOS); the contents pane must add a second, independently
        // scrolling one rather than squeezing arbitrarily long log text into
        // a fixed-height box.
        let scrollViews = descendants(in: hostingView).compactMap { $0 as? NSScrollView }
        #expect(scrollViews.count >= 2, "expected the entry list and the contents pane to each own a scroll view")
    }
}

@MainActor
private func descendants(in view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap { descendants(in: $0) }
}

@MainActor
private func makeHostingView<Content: View>(_ rootView: Content, size: NSSize) -> NSHostingView<Content> {
    let hostingView = NSHostingView(rootView: rootView)
    hostingView.frame = NSRect(origin: .zero, size: size)
    hostingView.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    hostingView.layoutSubtreeIfNeeded()
    return hostingView
}
