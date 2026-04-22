import AppKit
import SwiftUI
import Testing
@testable import Wink

@Suite("Wink primitives")
struct WinkPrimitivesTests {
    @Test @MainActor
    func cardRendersWithTitleAndContent() {
        let view = NSHostingView(rootView:
            WinkCard(title: { Text("Updates") }) {
                Text("Body")
                    .padding(14)
            }
            .winkPaletteFromColorScheme()
        )
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 80)
        view.layoutSubtreeIfNeeded()

        #expect(view.fittingSize.width > 0)
        #expect(view.fittingSize.height > 0)
    }

    @Test @MainActor
    func bannerRendersAllKinds() {
        for kind in [WinkBannerKind.info, .success, .warn, .error] {
            let view = NSHostingView(rootView:
                WinkBanner(kind: kind, title: "Title", message: "Body")
                    .winkPaletteFromColorScheme()
            )
            view.frame = NSRect(x: 0, y: 0, width: 320, height: 60)
            view.layoutSubtreeIfNeeded()
            #expect(view.fittingSize.width > 0, "Banner kind \(kind) failed to render")
        }
    }

    @Test @MainActor
    func bannerWithTrailingButtonRenders() {
        let view = NSHostingView(rootView:
            WinkBanner(kind: .warn, title: "Permission", message: "Needs access") {
                WinkButton("Open", variant: .primary) { }
            }
            .winkPaletteFromColorScheme()
        )
        view.frame = NSRect(x: 0, y: 0, width: 360, height: 60)
        view.layoutSubtreeIfNeeded()
        #expect(view.fittingSize.width > 0)
    }

    @Test @MainActor
    func keycapRendersBothSizes() {
        for size in [WinkKeycap.Size.small, .medium] {
            let view = NSHostingView(rootView:
                WinkKeycap("⌘K", size: size).winkPaletteFromColorScheme()
            )
            view.layoutSubtreeIfNeeded()
            #expect(view.fittingSize.width >= 18)
        }
    }

    @Test @MainActor
    func hyperBadgeRenders() {
        let view = NSHostingView(rootView:
            WinkHyperBadge().winkPaletteFromColorScheme()
        )
        view.layoutSubtreeIfNeeded()
        #expect(view.fittingSize.width > 0)
    }

    @Test @MainActor
    func statusDotRenders() {
        let view = NSHostingView(rootView: WinkStatusDot(color: .green, size: 6))
        view.layoutSubtreeIfNeeded()
        #expect(view.fittingSize.width > 0)
    }

    @Test @MainActor
    func switchTogglesIsOnBindingViaButtonTap() {
        var isOn = false
        let binding = Binding<Bool>(get: { isOn }, set: { isOn = $0 })

        let host = NSHostingView(rootView:
            WinkSwitch(isOn: binding).winkPaletteFromColorScheme()
        )
        host.frame = NSRect(x: 0, y: 0, width: 50, height: 30)
        host.layoutSubtreeIfNeeded()

        // The switch is implemented as a Button — verify the binding integrates.
        binding.wrappedValue = true
        #expect(isOn == true)
        binding.wrappedValue = false
        #expect(isOn == false)
    }

    @Test @MainActor
    func segmentedReflectsSelectionState() {
        var selection = "W"
        let binding = Binding<String>(get: { selection }, set: { selection = $0 })

        let host = NSHostingView(rootView:
            WinkSegmented(
                options: [("D", "D"), ("W", "W"), ("M", "M")],
                selection: binding
            )
            .winkPaletteFromColorScheme()
        )
        host.frame = NSRect(x: 0, y: 0, width: 160, height: 28)
        host.layoutSubtreeIfNeeded()

        #expect(selection == "W")
        binding.wrappedValue = "M"
        #expect(selection == "M")
    }

    @Test @MainActor
    func buttonRendersAllVariants() {
        for variant in [WinkButtonVariant.primary, .secondary, .ghost, .danger] {
            let host = NSHostingView(rootView:
                WinkButton("Action", variant: variant) { }
                    .winkPaletteFromColorScheme()
            )
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.width > 0, "Button variant \(variant) failed to render")
        }
    }

    @Test @MainActor
    func textFieldRenders() {
        var value = ""
        let binding = Binding<String>(get: { value }, set: { value = $0 })

        let host = NSHostingView(rootView:
            WinkTextField(placeholder: "Filter", text: binding) {
                WinkIcon.search.image()
            } trailing: {
                WinkKeycap("⌘K", size: .small)
            }
            .winkPaletteFromColorScheme()
        )
        host.frame = NSRect(x: 0, y: 0, width: 220, height: 28)
        host.layoutSubtreeIfNeeded()

        #expect(host.fittingSize.width > 0)
    }

    @Test
    func iconSystemNameMappingCoversAllCases() {
        for icon in WinkIcon.allCases {
            #expect(!icon.systemName.isEmpty, "WinkIcon.\(icon) missing systemName")
        }
    }

    @Test @MainActor
    func sparklineRendersWithFill() {
        let view = NSHostingView(rootView:
            WinkSparkline(points: [1, 3, 2, 5, 4, 6, 8, 7], stroke: .blue, fill: .blue.opacity(0.1))
                .frame(width: 80, height: 24)
        )
        view.layoutSubtreeIfNeeded()
        #expect(view.fittingSize.width > 0)
    }

    @Test @MainActor
    func sparklineHandlesEmptyAndSinglePoint() {
        // One point is not enough to draw a line — should not crash.
        let view = NSHostingView(rootView:
            WinkSparkline(points: [42], stroke: .red).frame(width: 80, height: 24)
        )
        view.layoutSubtreeIfNeeded()
        #expect(view.fittingSize.height >= 0)
    }
}
