import AppKit
import SwiftUI
import Testing
@testable import Wink

@Suite("Layout regressions")
struct LayoutRegressionTests {
    @Test @MainActor
    func insightsRankingUsesScrollViewWhenRankingIsPopulated() async {
        let shortcutId = UUID()
        let store = ShortcutStore()
        store.replaceAll(with: [
            AppShortcut(
                id: shortcutId,
                appName: "Safari",
                bundleIdentifier: "com.apple.Safari",
                keyEquivalent: "s",
                modifierFlags: ["command"]
            )
        ])

        let viewModel = InsightsViewModel(
            usageTracker: StaticUsageTracker(shortcutId: shortcutId),
            shortcutStore: store
        )
        await viewModel.refresh(for: .week)

        let hostingView = makeHostingView(
            InsightsTabView(viewModel: viewModel),
            size: NSSize(width: 680, height: 420)
        )

        #expect(containsDescendant(in: hostingView) { $0 is NSScrollView })
    }

    @Test @MainActor
    func cardViewExpandsToFillWidthInsideLeadingStack() {
        let hostingView = makeHostingView(
            CardWidthProbeView(),
            size: NSSize(width: 720, height: 220)
        )

        let widestDirectSubview = hostingView.subviews
            .map(\.frame.width)
            .max() ?? 0

        #expect(widestDirectSubview >= 660)
    }
}

private actor StaticUsageTracker: UsageTracking {
    let shortcutId: UUID

    init(shortcutId: UUID) {
        self.shortcutId = shortcutId
    }

    func usageCounts(days: Int, relativeTo now: Date) async -> [UUID: Int] {
        [shortcutId: 732]
    }

    func dailyCounts(days: Int, relativeTo now: Date) async -> [String: [(date: String, count: Int)]] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current

        return [
            shortcutId.uuidString: [
                (date: formatter.string(from: now), count: 611),
            ]
        ]
    }

    func totalSwitches(days: Int, relativeTo now: Date) async -> Int {
        732
    }
}

private struct CardWidthProbeView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardView("Startup") {
                Text("Launch at Login")
                    .padding(14)
            }

            Spacer()
        }
        .frame(width: 680, height: 180)
        .padding(20)
    }
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

@MainActor
private func containsDescendant(
    in view: NSView,
    where matches: (NSView) -> Bool
) -> Bool {
    if matches(view) {
        return true
    }

    for subview in view.subviews {
        if containsDescendant(in: subview, where: matches) {
            return true
        }
    }

    return false
}
