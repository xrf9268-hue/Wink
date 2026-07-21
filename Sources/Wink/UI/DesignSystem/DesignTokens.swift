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
        // chrome.jsx's Sidebar also defines sidebarItemActive (flat rgba row
        // overlay for the *selected* row) — Wink's sidebar is a real SwiftUI
        // List(selection:) with .listStyle(.sidebar), so row selection comes
        // from AppKit's native accent-color highlight instead; carrying that
        // token with no consumer read as unreviewed drift. sidebarItemHover
        // does have a real consumer (the menu bar popover's row hover state),
        // so it stays.
        let sidebarBg: Color
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
        /// tokens.jsx `controlShadow`: a subtle 0.5px top-edge highlight,
        /// e.g. `.shadow(color: controlShadowColor, radius: 0, y: 0.5)`.
        let controlShadowColor: Color
        let fieldBg: Color
        let fieldBorder: Color
        let progressTrackBg: Color

        // Accents.
        //
        // The brand accent is Wink amber (2026-07 rebrand, matching the
        // landing page / design-system identity). `amber` remains a separate
        // semantic token for warn/attention states but intentionally shares
        // the accent values — warn states are distinguished by icon and
        // context, never by hue alone. The former `violet` Hyper tokens are
        // gone: Hyper is the brand moment, so it wears the accent.
        let accent: Color
        let accentHover: Color
        let accentBgSoft: Color
        let accentBorderSoft: Color
        let green: Color
        let greenSoft: Color
        let red: Color
        let redBgSoft: Color
        let redBorderSoft: Color
        let amber: Color
        let amberBgSoft: Color

        // Misc
        let heatmapEmpty: Color
        let focusRing: Color

        /// Fixed neutral grey for the "no app chosen" placeholder swatch.
        /// A deliberately fixed hue rather than a translucent control token —
        /// mirrors tab-shortcuts.jsx:66's literal `#D8D8D8`/`#5A5A5C`.
        let appPlaceholderSwatchBg: Color
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
        controlShadowColor: .winkBlack(0.04),
        fieldBg:        .winkSRGB(0xFF, 0xFF, 0xFF),
        fieldBorder:    .winkBlack(0.10),
        progressTrackBg: .winkBlack(0.04),

        // Deep amber: 4.75:1 against white, so textOnAccent (.white) stays AA
        // on filled controls. Soft tints use the brighter #E08A00 so washes
        // read warm rather than brown.
        accent:           .winkSRGB(0xA8, 0x62, 0x0A),
        accentHover:      .winkSRGB(0x96, 0x59, 0x0A),
        accentBgSoft:     .winkSRGB(0xE0, 0x8A, 0x00, 0.10),
        accentBorderSoft: .winkSRGB(0xE0, 0x8A, 0x00, 0.22),
        green:            .winkSRGB(0x2E, 0xA0, 0x45),
        greenSoft:        .winkSRGB(0x2E, 0xA0, 0x45, 0.10),
        red:              .winkSRGB(0xD1, 0x3B, 0x3B),
        redBgSoft:        .winkSRGB(0xD1, 0x3B, 0x3B, 0.08),
        redBorderSoft:    .winkSRGB(0xD1, 0x3B, 0x3B, 0.20),
        amber:            .winkSRGB(0xA8, 0x62, 0x0A),
        amberBgSoft:      .winkSRGB(0xE0, 0x8A, 0x00, 0.10),

        heatmapEmpty:   .winkBlack(0.04),
        focusRing:      .winkSRGB(0xE0, 0x8A, 0x00, 0.40),

        appPlaceholderSwatchBg: .winkSRGB(0xD8, 0xD8, 0xD8)
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
        sidebarItemHover:    .winkWhite(0.04),

        // tokens.jsx darkTheme: textSecondary/textTertiary use Apple's
        // tinted near-white (rgba(235,235,245,…), the systemGray-family
        // secondary/tertiary label tint), not pure white — textPrimary is
        // the only one that's actually pure white at full-ish opacity.
        textPrimary:    .winkWhite(0.92),
        textSecondary:  .winkSRGB(0xEB, 0xEB, 0xF5, 0.55),
        textTertiary:   .winkSRGB(0xEB, 0xEB, 0xF5, 0.32),
        // Dark ink on the bright amber fill (≈10.9:1) — white would be
        // illegible on #FFB454. Mirrors the landing page's dark-theme CTA.
        textOnAccent:   .winkSRGB(0x1A, 0x12, 0x06),

        hairline:        .winkWhite(0.08),
        hairlineStrong:  .winkWhite(0.14),

        controlBg:      .winkSRGB(0x3A, 0x3A, 0x3C),
        controlBgRest:  .winkSRGB(0x2E, 0x2E, 0x30),
        controlBorder:  .winkWhite(0.10),
        controlShadowColor: .winkWhite(0.04),
        fieldBg:        .winkSRGB(0x2A, 0x2A, 0x2C),
        fieldBorder:    .winkWhite(0.08),
        progressTrackBg: .winkWhite(0.05),

        accent:           .winkSRGB(0xFF, 0xB4, 0x54),
        accentHover:      .winkSRGB(0xFF, 0xC3, 0x77),
        accentBgSoft:     .winkSRGB(0xFF, 0xB4, 0x54, 0.15),
        accentBorderSoft: .winkSRGB(0xFF, 0xB4, 0x54, 0.30),
        green:            .winkSRGB(0x40, 0xC0, 0x60),
        greenSoft:        .winkSRGB(0x40, 0xC0, 0x60, 0.16),
        red:              .winkSRGB(0xFF, 0x5F, 0x58),
        redBgSoft:        .winkSRGB(0xFF, 0x5F, 0x58, 0.12),
        redBorderSoft:    .winkSRGB(0xFF, 0x5F, 0x58, 0.24),
        amber:            .winkSRGB(0xFF, 0xB4, 0x54),
        amberBgSoft:      .winkSRGB(0xFF, 0xB4, 0x54, 0.15),

        heatmapEmpty:   .winkWhite(0.04),
        focusRing:      .winkSRGB(0xFF, 0xB4, 0x54, 0.45),

        appPlaceholderSwatchBg: .winkSRGB(0x5A, 0x5A, 0x5C)
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
    /// Designate this view as the root of a Wink-styled hosting boundary.
    ///
    /// **Apply this once at the root of every Scene's content closure
    /// and at every `NSHostingView` / `NSHostingController` rootView.**
    /// SwiftUI's environment flows down a single view tree, but each new
    /// hosting boundary starts a fresh tree — without this modifier, the
    /// downstream `@Environment(\.winkPalette)` reads the default
    /// (light) palette regardless of the surrounding `colorScheme`.
    ///
    /// Inside a single hosting tree, every child view inherits the
    /// palette automatically; you do not need to repeat the modifier.
    func winkChromeRoot() -> some View {
        modifier(WinkChromeRoot())
    }
}

private struct WinkChromeRoot: ViewModifier {
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
    static let tabSubtitle  = Font.system(size: 12, weight: .regular)
    static let bodyText     = Font.system(size: 13, weight: .regular)
    static let bodyMedium   = Font.system(size: 13, weight: .medium)
    /// chrome.jsx Sidebar row label: `fontSize: 13, fontWeight: 400`.
    static let sidebarRow   = Font.system(size: 13, weight: .regular)
    static let labelSmall   = Font.system(size: 11, weight: .regular)
    static let captionStrong = Font.system(size: 11, weight: .semibold)
    static let kpiValue     = Font.system(size: 26, weight: .semibold)

    /// Tabular monospaced digits used for shortcut keycaps and counters.
    static let monoBadge = Font.system(size: 12, weight: .medium, design: .monospaced)
    static let monoSmall = Font.system(size: 11, weight: .medium, design: .monospaced)
}
