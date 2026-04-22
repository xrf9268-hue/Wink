import SwiftUI

/// Wink logo marks for the v2 design.
///
/// Mirrors `wink/project/v2/logos.jsx` from the Claude Design handoff.
/// `Twin` is the anchor mark adopted across menu bar, dock and wordmark
/// per the 2026-04-22 review decision.
///
/// The closed eye is drawn as a concave-up arc — in SVG/SwiftUI y-down
/// coordinates that means the control point's y is *larger* than the end
/// points', so the middle of the arc dips below the ends. Paired with a
/// solid dot to the right it reads unambiguously as "closed smiling eye
/// + open eye" — v1's inverted arc looked like a frown.
struct Logo_WinkTwin: View {
    var size: CGFloat = 64
    var color: Color = .primary

    var body: some View {
        Canvas { context, canvasSize in
            // viewBox 32×32 to match the JSX source.
            let scale = canvasSize.width / 32

            // Closed eye: concave-up quadratic curve.
            var closedEye = Path()
            closedEye.move(to: CGPoint(x: 5.5 * scale, y: 13.5 * scale))
            closedEye.addQuadCurve(
                to: CGPoint(x: 15.5 * scale, y: 13.5 * scale),
                control: CGPoint(x: 10.5 * scale, y: 18.5 * scale)
            )
            context.stroke(
                closedEye,
                with: .color(color),
                style: StrokeStyle(lineWidth: 2.8 * scale, lineCap: .round)
            )

            // Open eye: solid dot, vertically centered on the arc baseline.
            let dotRadius = 2.9 * scale
            let dot = Path(ellipseIn: CGRect(
                x: 23 * scale - dotRadius,
                y: 15.5 * scale - dotRadius,
                width: dotRadius * 2,
                height: dotRadius * 2
            ))
            context.fill(dot, with: .color(color))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Product app icon — Twin on a violet→blue gradient squircle. Used in
/// the menu bar popover header, About card and dock icon (Phase 4).
struct WinkAppIcon: View {
    var size: CGFloat = 28
    var cornerRadius: CGFloat?

    var body: some View {
        let radius = cornerRadius ?? size * 0.24
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        .winkSRGB(0x5B, 0x8D, 0xEF),  // #5B8DEF
                        .winkSRGB(0x8A, 0x6C, 0xF0),  // #8A6CF0
                        .winkSRGB(0xB8, 0x6C, 0xD9)   // #B86CD9
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                Logo_WinkTwin(size: size * 0.7, color: .white)
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
