import SwiftUI

/// Wink logo marks for the v2 design.
///
/// Mirrors `wink/project/v2/logos.jsx` from the Claude Design handoff.
/// `Twin` is the anchor mark adopted across menu bar, dock and wordmark
/// per the 2026-04-22 review decision.
///
/// The closed eye is the circle-subtraction crescent from the latest
/// logo options/UI v2 design: an outer disc at (12,16), r=9, cut by an
/// inner disc at (15.2,13.4), r=8. Paired with the open-eye dot at
/// (25,16), r=2.2, this matches the checked-in SVG app/menu assets.
struct Logo_WinkTwin: View {
    var size: CGFloat = 64
    var color: Color = .primary

    var body: some View {
        Canvas { context, canvasSize in
            // viewBox 32×32 to match the JSX source.
            let scale = canvasSize.width / 32

            var crescent = Path()
            crescent.addEllipse(in: CGRect(
                x: (12 - 9) * scale,
                y: (16 - 9) * scale,
                width: 18 * scale,
                height: 18 * scale
            ))
            crescent.addEllipse(in: CGRect(
                x: (15.2 - 8) * scale,
                y: (13.4 - 8) * scale,
                width: 16 * scale,
                height: 16 * scale
            ))
            context.fill(
                crescent,
                with: .color(color),
                style: FillStyle(eoFill: true)
            )

            // Open eye: solid dot aligned to the crescent's optical center.
            let dotRadius = 2.2 * scale
            let dot = Path(ellipseIn: CGRect(
                x: 25 * scale - dotRadius,
                y: 16 * scale - dotRadius,
                width: dotRadius * 2,
                height: dotRadius * 2
            ))
            context.fill(dot, with: .color(color))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Product app icon — amber Twin on an ink-navy gradient squircle
/// (2026-07 amber rebrand, matching the landing-page identity). Used in
/// the menu bar popover header, About card and dock icon (Phase 4).
///
/// Two overlays stacked on the gradient mirror the JSX source:
/// 1. a faint white top-edge gradient that mimics CSS
///    `inset 0 0.5px 0 rgba(255,255,255,0.35)` — gives the squircle the
///    same lit-from-above feel as native macOS Sequoia app tiles, and
/// 2. the Twin mark itself, rendered in white at 70% of the tile size.
struct WinkAppIcon: View {
    var size: CGFloat = 28
    var cornerRadius: CGFloat?

    var body: some View {
        let radius = cornerRadius ?? size * 0.24
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        shape
            .fill(
                LinearGradient(
                    colors: [
                        .winkSRGB(0x1E, 0x26, 0x38),  // #1E2638
                        .winkSRGB(0x10, 0x14, 0x1E),  // #10141E
                        .winkSRGB(0x0A, 0x0D, 0x14)   // #0A0D14
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                // Inset top highlight — a subtle 18% white wash (the old 35%
                // read milky on the dark ink tile) fading out by mid-tile.
                LinearGradient(
                    colors: [.winkWhite(0.18), .clear],
                    startPoint: .top,
                    endPoint: .center
                )
                .clipShape(shape)
                .allowsHitTesting(false)
            )
            .overlay(
                Logo_WinkTwin(size: size * 0.7, color: .winkSRGB(0xFF, 0xB4, 0x54))
            )
            .frame(width: size, height: size)
            .shadow(color: .winkBlack(0.12), radius: 1, y: 0.5)
            .accessibilityHidden(true)
    }
}

/// Typeset "Wink" with the lowercase i replaced by a winking tittle.
/// Used in the menu bar popover header and Updates card.
///
/// Both fragments are `verbatim`. A bare `Text("W")` is a `LocalizedStringKey`
/// resolved against the main bundle, and the app ships a real "W" key — the
/// Insights range abbreviation for Week — so the wordmark rendered as "周ink"
/// in Chinese. A brand name is never a translatable string.
struct WinkWordmark: View {
    var size: CGFloat = 20
    var color: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(verbatim: "W")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(color)

            WinkingI(size: size, color: color)

            Text(verbatim: "nk")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(color)
        }
        .kerning(-0.5)
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: "Wink"))
    }
}

/// Lowercase i with the dot replaced by a winking arc.
///
/// Proportions are fractions of the wordmark's font size, taken from SF Pro:
/// the stem rises to **x-height**, and the tittle floats a clear gap above it,
/// topping out at cap height so the mark sits level with the "W" and "k".
///
/// The stem used to be drawn at `0.7 × size` — that is SF Pro's *cap* height,
/// which made the glyph as tall as the "W" beside it and pushed the tittle
/// down until it touched the stem. The wordmark read "WInk", not "Wink".
struct WinkingI: View {
    let size: CGFloat
    let color: Color

    /// All fractions of the wordmark's point size.
    ///
    /// `stemHeight` is SF Pro's x-height. The stem plus the gap plus the arc
    /// come to 0.74 — just past cap height (0.70), which is where a real
    /// tittle sits relative to the "k" beside it.
    private static let stemHeight: CGFloat = 0.52
    private static let stemWidth: CGFloat = 0.11
    private static let tittleGap: CGFloat = 0.06
    private static let tittleHeight: CGFloat = 0.16
    private static let tittleWidth: CGFloat = 0.40
    private static let tittleStroke: CGFloat = 0.075

    var body: some View {
        let stemWidth = max(1.5, size * Self.stemWidth)
        let tittleWidth = size * Self.tittleWidth

        VStack(spacing: size * Self.tittleGap) {
            // Winking tittle — same concave-up arc as Twin's closed eye.
            Canvas { context, canvasSize in
                let strokeWidth = max(1.2, size * Self.tittleStroke)
                // Round caps overhang the path by half the stroke, so the
                // path itself has to sit a half-stroke inside the box.
                let inset = strokeWidth / 2
                // A quadratic's midpoint is ¼·start + ½·control + ¼·end, so
                // this control lands the apex exactly one inset above the
                // bottom edge — the arc fills its box without clipping.
                let control = 2 * canvasSize.height - 3 * inset

                var path = Path()
                path.move(to: CGPoint(x: inset, y: inset))
                path.addQuadCurve(
                    to: CGPoint(x: canvasSize.width - inset, y: inset),
                    control: CGPoint(x: canvasSize.width / 2, y: control)
                )
                context.stroke(
                    path,
                    with: .color(color),
                    style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round)
                )
            }
            .frame(width: tittleWidth, height: size * Self.tittleHeight)

            // i stem — Capsule keeps round caps consistent with SF Pro.
            Capsule()
                .fill(color)
                .frame(width: stemWidth, height: size * Self.stemHeight)
        }
        .frame(width: max(stemWidth, tittleWidth))
        // A shape has no text baseline of its own, so the HStack would fall
        // back to this view's bottom edge — which is already the stem's foot.
        // Stating it keeps that true if the stack ever gains padding.
        .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
        .accessibilityHidden(true)
    }
}
