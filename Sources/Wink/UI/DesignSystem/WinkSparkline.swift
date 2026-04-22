import SwiftUI

/// Compact sparkline used by Insights KPI cards and per-app rows.
///
/// Pure `Path` rendering on a `Canvas` — no shape libraries, no animation
/// dependencies. The `points` array maps left-to-right; the highest value
/// touches the top of the frame minus a 1pt safety inset.
struct WinkSparkline: View {
    let points: [Double]
    var stroke: Color
    var fill: Color = .clear
    var lineWidth: CGFloat = 1.4

    init(points: [Int], stroke: Color, fill: Color = .clear, lineWidth: CGFloat = 1.4) {
        self.points = points.map(Double.init)
        self.stroke = stroke
        self.fill = fill
        self.lineWidth = lineWidth
    }

    init(points: [Double], stroke: Color, fill: Color = .clear, lineWidth: CGFloat = 1.4) {
        self.points = points
        self.stroke = stroke
        self.fill = fill
        self.lineWidth = lineWidth
    }

    var body: some View {
        Canvas { context, size in
            guard points.count > 1 else { return }
            let maxValue = max(1.0, points.max() ?? 1.0)
            let stepX = size.width / CGFloat(points.count - 1)
            let usableHeight = size.height - 2

            var line = Path()
            for (index, value) in points.enumerated() {
                let x = CGFloat(index) * stepX
                let y = size.height - (CGFloat(value / maxValue) * usableHeight) - 1
                if index == 0 {
                    line.move(to: CGPoint(x: x, y: y))
                } else {
                    line.addLine(to: CGPoint(x: x, y: y))
                }
            }

            // Area fill (only if a non-clear fill was provided).
            if fill != .clear {
                var area = line
                area.addLine(to: CGPoint(x: size.width, y: size.height))
                area.addLine(to: CGPoint(x: 0, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .color(fill))
            }

            context.stroke(
                line,
                with: .color(stroke),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            )
        }
    }
}
