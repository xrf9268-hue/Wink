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
struct WinkWordmark: View {
    var size: CGFloat = 20
    var color: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("W")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(color)

            WinkingI(size: size, color: color)

            Text("nk")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(color)
        }
        .kerning(-0.5)
        .accessibilityElement()
        .accessibilityLabel("Wink")
    }
}

/// Lowercase i with the dot replaced by a winking arc. Sized relative
/// to the surrounding wordmark so it always tracks visual cap height.
private struct WinkingI: View {
    let size: CGFloat
    let color: Color

    var body: some View {
        let stemWidth = max(1.5, size * 0.11)
        let stemHeight = size * 0.7
        let tittleWidth = size * 0.44
        let tittleHeight = size * 0.28

        ZStack {
            // i stem — Capsule keeps round caps consistent with SF Pro.
            Capsule()
                .fill(color)
                .frame(width: stemWidth, height: stemHeight)
                .offset(y: size * 0.05)

            // Winking tittle — same concave-up arc as Twin's closed eye.
            Canvas { context, canvasSize in
                let sx = canvasSize.width / 16
                let sy = canvasSize.height / 10
                var path = Path()
                path.move(to: CGPoint(x: 2 * sx, y: 3 * sy))
                path.addQuadCurve(
                    to: CGPoint(x: 14 * sx, y: 3 * sy),
                    control: CGPoint(x: 8 * sx, y: 9 * sy)
                )
                let strokeWidth = 2.4 * min(sx, sy)
                context.stroke(
                    path,
                    with: .color(color),
                    style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round)
                )
            }
            .frame(width: tittleWidth, height: tittleHeight)
            .offset(y: -size * 0.32)
        }
        .frame(width: max(stemWidth, tittleWidth), height: size)
        .accessibilityHidden(true)
    }
}
