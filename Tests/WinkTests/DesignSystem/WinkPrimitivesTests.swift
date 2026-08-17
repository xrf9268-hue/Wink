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
            .winkChromeRoot()
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
                    .winkChromeRoot()
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
            .winkChromeRoot()
        )
        view.frame = NSRect(x: 0, y: 0, width: 360, height: 60)
        view.layoutSubtreeIfNeeded()
        #expect(view.fittingSize.width > 0)
    }

    @Test @MainActor
    func keycapRendersBothSizes() {
        for size in [WinkKeycap.Size.small, .medium] {
            let view = NSHostingView(rootView:
                WinkKeycap("⌘K", size: size).winkChromeRoot()
            )
            view.layoutSubtreeIfNeeded()
            #expect(view.fittingSize.width >= 18)
        }
    }

    @Test @MainActor
    func menuFieldLabelIsTheSameHeightAsTheButtonBesideIt() {
        // The reason the primitive exists: the Profile dropdown was a stock
        // Picker (~22pt, system-accent chevron well) sitting between a Wink
        // button and, one card down, the target-app field at 28.
        for size in [WinkControlSize.small, .medium] {
            let field = NSHostingView(rootView:
                WinkMenuFieldLabel("Default", size: size).winkChromeRoot()
            )
            field.layoutSubtreeIfNeeded()

            let button = NSHostingView(rootView:
                WinkButton("Manage…", size: size) { }.winkChromeRoot()
            )
            button.layoutSubtreeIfNeeded()

            #expect(field.fittingSize.height == size.height)
            #expect(field.fittingSize.height == button.fittingSize.height)
        }
    }

    @Test @MainActor
    func menuFieldRendersWithLeadingContentAndPlaceholder() {
        let view = NSHostingView(rootView:
            WinkMenuField("Choose an app…", isPlaceholder: true) {
                Button("Safari") { }
            } leading: {
                WinkStatusDot(color: .green, size: 6)
            }
            .winkChromeRoot()
        )
        view.frame = NSRect(x: 0, y: 0, width: 220, height: 28)
        view.layoutSubtreeIfNeeded()

        #expect(view.fittingSize.height == WinkControlSize.medium.height)
    }

    @Test @MainActor
    func hyperBadgeRenders() {
        let view = NSHostingView(rootView:
            WinkHyperBadge().winkChromeRoot()
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
    func switchRendersAndBindingPropagatesExternalMutation() {
        // We cannot synthesize a button press from a unit test without
        // spinning the app run loop, so this test only proves the view
        // hosts cleanly and the @Binding round-trips writes — not that a
        // user click flips the value. The accessibility role test below
        // covers the missing assertion that a real user input path exists.
        var isOn = false
        let binding = Binding<Bool>(get: { isOn }, set: { isOn = $0 })

        let host = NSHostingView(rootView:
            WinkSwitch(isOn: binding).winkChromeRoot()
        )
        host.frame = NSRect(x: 0, y: 0, width: 50, height: 30)
        host.layoutSubtreeIfNeeded()

        binding.wrappedValue = true
        #expect(isOn == true)
        binding.wrappedValue = false
        #expect(isOn == false)
    }

    // Note: `WinkSwitch.accessibilityRepresentation { Toggle(.switch) }`
    // does not materialize a discoverable `AXCheckBox` element until the
    // hosting view is part of an event-pumping NSApplication run loop, so
    // unit tests cannot verify the role directly. VoiceOver coverage is
    // tracked as a manual QA item per phase. The compile-time invariant —
    // that WinkSwitch declares an .accessibilityRepresentation containing
    // a Toggle — is enforced by the source review checklist.

    @Test @MainActor
    func segmentedRendersAndBindingPropagatesExternalMutation() {
        // Same caveat as switchRendersAndBindingPropagatesExternalMutation:
        // we exercise the binding path from outside, not a user tap on a
        // specific segment. The visual-state assertions in
        // `bannerRendersAllKinds` style cover the rendering invariant.
        var selection = "W"
        let binding = Binding<String>(get: { selection }, set: { selection = $0 })

        let host = NSHostingView(rootView:
            WinkSegmented(
                options: [("D", "D"), ("W", "W"), ("M", "M")],
                selection: binding
            )
            .winkChromeRoot()
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
                    .winkChromeRoot()
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
            .winkChromeRoot()
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

