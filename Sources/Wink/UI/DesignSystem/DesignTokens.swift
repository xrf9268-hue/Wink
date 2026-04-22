import SwiftUI

/// Native macOS Sequoia design tokens for Wink.
///
/// Mirrors `wink/project/v2/tokens.jsx` from the Claude Design v2 handoff.
/// Light and dark palettes are kept as plain `Color` constants rather than
/// asset catalog entries so the values are visible in code review.
///
/// - Note: All `rgba(0, 0, 0, …)` opacity-derived tokens are emitted as
///   `Color(.sRGB, white:opacity:)` to preserve the JSX semantics exactly.
enum WinkPalette {
    struct Tokens {
        // Window chrome
        let chromeBg: Color
        let chromeBorder: Color

        // Content canvases
        let windowBg: Color
        let cardBg: Color
        let cardBorder: Color
        let cardShadowColor: Color
        let cardShadowRadius: CGFloat
        let cardShadowY: CGFloat

        // Sidebar (vibrancy-ish)
        let sidebarBg: Color
        let sidebarItemActive: Color
        let sidebarItemHover: Color

        // Text
        let textPrimary: Color
        let textSecondary: Color
        let textTertiary: Color
        let textOnAccent: Color

        // Separators
        let hairline: Color
        let hairlineStrong: Color

        // Controls
        let controlBg: Color
        let controlBgRest: Color
        let controlBorder: Color
        let fieldBg: Color
        let fieldBorder: Color

        // Accents
        let accent: Color
        let accentHover: Color
        let accentBgSoft: Color
        let accentBorderSoft: Color
        let violet: Color
        let violetBgSoft: Color
        let green: Color
        let greenSoft: Color
        let red: Color
        let redBgSoft: Color
        let redBorderSoft: Color
        let amber: Color
        let amberBgSoft: Color

        // Misc
        let heatmapBase: Color
        let focusRing: Color
    }

    static let light = Tokens(
        chromeBg:        .winkSRGB(0xEC, 0xEC, 0xEC),
        chromeBorder:    .winkBlack(0.10),

        windowBg:        .winkSRGB(0xF5, 0xF5, 0xF5),
        cardBg:          .winkSRGB(0xFF, 0xFF, 0xFF),
        cardBorder:      .winkBlack(0.06),
        cardShadowColor: .winkBlack(0.04),
        cardShadowRadius: 2,
        cardShadowY:     1,

        sidebarBg:           .winkSRGB(0xE8, 0xE8, 0xE8),
        sidebarItemActive:   .winkBlack(0.08),
        sidebarItemHover:    .winkBlack(0.04),

        textPrimary:    .winkBlack(0.88),
        textSecondary:  .winkBlack(0.55),
        textTertiary:   .winkBlack(0.38),
        textOnAccent:   .white,

        hairline:        .winkBlack(0.08),
        hairlineStrong:  .winkBlack(0.14),

        controlBg:      .winkSRGB(0xFF, 0xFF, 0xFF),
        controlBgRest:  .winkSRGB(0xFD, 0xFD, 0xFD),
        controlBorder:  .winkBlack(0.14),
        fieldBg:        .winkSRGB(0xFF, 0xFF, 0xFF),
        fieldBorder:    .winkBlack(0.10),

        accent:           .winkSRGB(0x00, 0x64, 0xE0),
        accentHover:      .winkSRGB(0x00, 0x4F, 0xC2),
        accentBgSoft:     .winkSRGB(0x00, 0x64, 0xE0, 0.08),
        accentBorderSoft: .winkSRGB(0x00, 0x64, 0xE0, 0.18),
        violet:           .winkSRGB(0x6B, 0x48, 0xC9),
        violetBgSoft:     .winkSRGB(0x6B, 0x48, 0xC9, 0.10),
        green:            .winkSRGB(0x2E, 0xA0, 0x45),
        greenSoft:        .winkSRGB(0x2E, 0xA0, 0x45, 0.10),
        red:              .winkSRGB(0xD1, 0x3B, 0x3B),
        redBgSoft:        .winkSRGB(0xD1, 0x3B, 0x3B, 0.08),
        redBorderSoft:    .winkSRGB(0xD1, 0x3B, 0x3B, 0.20),
        amber:            .winkSRGB(0xC7, 0x78, 0x00),
        amberBgSoft:      .winkSRGB(0xC7, 0x78, 0x00, 0.10),

        heatmapBase:    .winkSRGB(0x00, 0x64, 0xE0, 0.10),
        focusRing:      .winkSRGB(0x00, 0x64, 0xE0, 0.35)
    )

    static let dark = Tokens(
        chromeBg:        .winkSRGB(0x2C, 0x2C, 0x2E),
        chromeBorder:    .winkWhite(0.08),

        windowBg:        .winkSRGB(0x1C, 0x1C, 0x1E),
        cardBg:          .winkSRGB(0x23, 0x23, 0x26),
        cardBorder:      .winkWhite(0.06),
        cardShadowColor: .winkBlack(0.30),
        cardShadowRadius: 3,
        cardShadowY:     1,

        sidebarBg:           .winkSRGB(0x25, 0x25, 0x27),
        sidebarItemActive:   .winkWhite(0.08),
        sidebarItemHover:    .winkWhite(0.04),

        textPrimary:    .winkWhite(0.92),
        textSecondary:  .winkWhite(0.55),
        textTertiary:   .winkWhite(0.32),
        textOnAccent:   .white,

        hairline:        .winkWhite(0.08),
        hairlineStrong:  .winkWhite(0.14),

        controlBg:      .winkSRGB(0x3A, 0x3A, 0x3C),
        controlBgRest:  .winkSRGB(0x2E, 0x2E, 0x30),
        controlBorder:  .winkWhite(0.10),
        fieldBg:        .winkSRGB(0x2A, 0x2A, 0x2C),
        fieldBorder:    .winkWhite(0.08),

        accent:           .winkSRGB(0x2A, 0x8F, 0xFF),
        accentHover:      .winkSRGB(0x4A, 0xA0, 0xFF),
        accentBgSoft:     .winkSRGB(0x2A, 0x8F, 0xFF, 0.16),
        accentBorderSoft: .winkSRGB(0x2A, 0x8F, 0xFF, 0.28),
        violet:           .winkSRGB(0xA6, 0x89, 0xF0),
        violetBgSoft:     .winkSRGB(0xA6, 0x89, 0xF0, 0.18),
        green:            .winkSRGB(0x40, 0xC0, 0x60),
        greenSoft:        .winkSRGB(0x40, 0xC0, 0x60, 0.16),
        red:              .winkSRGB(0xFF, 0x5F, 0x58),
        redBgSoft:        .winkSRGB(0xFF, 0x5F, 0x58, 0.12),
        redBorderSoft:    .winkSRGB(0xFF, 0x5F, 0x58, 0.24),
        amber:            .winkSRGB(0xF5, 0xB5, 0x3F),
        amberBgSoft:      .winkSRGB(0xF5, 0xB5, 0x3F, 0.14),

        heatmapBase:    .winkSRGB(0x2A, 0x8F, 0xFF, 0.20),
        focusRing:      .winkSRGB(0x2A, 0x8F, 0xFF, 0.45)
    )

    static func tokens(for scheme: ColorScheme) -> Tokens {
        scheme == .dark ? dark : light
    }
}

/// SwiftUI `EnvironmentValue` for the active palette so views can read tokens
/// without re-deriving from `colorScheme` at every call site.
struct WinkPaletteEnvironmentKey: EnvironmentKey {
    static let defaultValue: WinkPalette.Tokens = WinkPalette.light
}

extension EnvironmentValues {
    var winkPalette: WinkPalette.Tokens {
        get { self[WinkPaletteEnvironmentKey.self] }
        set { self[WinkPaletteEnvironmentKey.self] = newValue }
    }
}

extension View {
    /// Inject the palette derived from the surrounding `colorScheme` so children
    /// can simply read `@Environment(\.winkPalette)`.
    func winkPaletteFromColorScheme() -> some View {
        modifier(WinkPaletteFromColorScheme())
    }
}

private struct WinkPaletteFromColorScheme: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.environment(\.winkPalette, WinkPalette.tokens(for: colorScheme))
    }
}

// MARK: - Color helpers

extension Color {
    /// sRGB color from 0–255 component values, matching the JSX `#RRGGBB` syntax.
    static func winkSRGB(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ opacity: Double = 1) -> Color {
        Color(.sRGB,
              red: Double(r) / 255.0,
              green: Double(g) / 255.0,
              blue: Double(b) / 255.0,
              opacity: opacity)
    }

    /// Black at the given opacity, matching `rgba(0,0,0,a)` in the JSX tokens.
    static func winkBlack(_ opacity: Double) -> Color {
        Color(.sRGB, red: 0, green: 0, blue: 0, opacity: opacity)
    }

    /// White at the given opacity, matching `rgba(255,255,255,a)` in the JSX tokens.
    static func winkWhite(_ opacity: Double) -> Color {
        Color(.sRGB, red: 1, green: 1, blue: 1, opacity: opacity)
    }
}

// MARK: - Typography

/// Typography tokens. Pin to SF system fonts so the wordmark and labels
/// match macOS chrome at every scale.
enum WinkType {
    static let sectionLabel = Font.system(size: 11, weight: .semibold)
    static let cardTitle    = Font.system(size: 12, weight: .semibold)
    static let tabTitle     = Font.system(size: 20, weight: .semibold)
    static let bodyText     = Font.system(size: 13, weight: .regular)
    static let bodyMedium   = Font.system(size: 13, weight: .medium)
    static let labelSmall   = Font.system(size: 11, weight: .regular)
    static let captionStrong = Font.system(size: 11, weight: .semibold)
    static let kpiValue     = Font.system(size: 26, weight: .semibold)

    /// Tabular monospaced digits used for shortcut keycaps and counters.
    static let monoBadge = Font.system(size: 12, weight: .medium, design: .monospaced)
    static let monoSmall = Font.system(size: 11, weight: .medium, design: .monospaced)
}
