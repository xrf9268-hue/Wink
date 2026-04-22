import AppKit
import SwiftUI
import Testing
@testable import Wink

@Suite("Design tokens")
struct DesignTokensTests {
    private static let tolerance: CGFloat = 0.005

    @Test
    func lightAndDarkPalettesAreDistinct() {
        let light = WinkPalette.light
        let dark = WinkPalette.dark

        #expect(light.windowBg != dark.windowBg)
        #expect(light.cardBg != dark.cardBg)
        #expect(light.accent != dark.accent)
    }

    @Test
    func lightTokensMatchDesignSpec() {
        let l = WinkPalette.light
        // Spot-check the values that anchor the v2 design — chrome, accent,
        // green status, hyper violet, hairline.
        assertSRGB(l.chromeBg, expected: (0xEC, 0xEC, 0xEC, 1.0))
        assertSRGB(l.windowBg, expected: (0xF5, 0xF5, 0xF5, 1.0))
        assertSRGB(l.cardBg,   expected: (0xFF, 0xFF, 0xFF, 1.0))
        assertSRGB(l.accent,   expected: (0x00, 0x64, 0xE0, 1.0))
        assertSRGB(l.violet,   expected: (0x6B, 0x48, 0xC9, 1.0))
        assertSRGB(l.green,    expected: (0x2E, 0xA0, 0x45, 1.0))
        assertSRGB(l.amber,    expected: (0xC7, 0x78, 0x00, 1.0))
        assertSRGB(l.hairline, expected: (0x00, 0x00, 0x00, 0.08))
        assertSRGB(l.textPrimary, expected: (0x00, 0x00, 0x00, 0.88))
    }

    @Test
    func darkTokensMatchDesignSpec() {
        let d = WinkPalette.dark
        assertSRGB(d.chromeBg, expected: (0x2C, 0x2C, 0x2E, 1.0))
        assertSRGB(d.windowBg, expected: (0x1C, 0x1C, 0x1E, 1.0))
        assertSRGB(d.cardBg,   expected: (0x23, 0x23, 0x26, 1.0))
        assertSRGB(d.accent,   expected: (0x2A, 0x8F, 0xFF, 1.0))
        assertSRGB(d.violet,   expected: (0xA6, 0x89, 0xF0, 1.0))
        assertSRGB(d.green,    expected: (0x40, 0xC0, 0x60, 1.0))
        assertSRGB(d.amber,    expected: (0xF5, 0xB5, 0x3F, 1.0))
        assertSRGB(d.hairline, expected: (0xFF, 0xFF, 0xFF, 0.08))
        assertSRGB(d.textPrimary, expected: (0xFF, 0xFF, 0xFF, 0.92))
    }

    @Test
    func tokensForColorSchemeReturnsCorrectVariant() {
        #expect(WinkPalette.tokens(for: .light).windowBg == WinkPalette.light.windowBg)
        #expect(WinkPalette.tokens(for: .dark).windowBg == WinkPalette.dark.windowBg)
    }

    @Test
    func paletteEnvironmentDefaultsToLight() {
        let env = EnvironmentValues()
        #expect(env.winkPalette.windowBg == WinkPalette.light.windowBg)
    }

    // MARK: - Helpers

    private func assertSRGB(
        _ color: Color,
        expected: (UInt8, UInt8, UInt8, CGFloat),
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let nsColor = NSColor(color).usingColorSpace(.sRGB)
        guard let resolved = nsColor else {
            Issue.record("Color did not resolve to sRGB color space", sourceLocation: sourceLocation)
            return
        }
        let r = resolved.redComponent
        let g = resolved.greenComponent
        let b = resolved.blueComponent
        let a = resolved.alphaComponent

        let expectedR = CGFloat(expected.0) / 255.0
        let expectedG = CGFloat(expected.1) / 255.0
        let expectedB = CGFloat(expected.2) / 255.0

        #expect(abs(r - expectedR) <= Self.tolerance, "red component mismatch", sourceLocation: sourceLocation)
        #expect(abs(g - expectedG) <= Self.tolerance, "green component mismatch", sourceLocation: sourceLocation)
        #expect(abs(b - expectedB) <= Self.tolerance, "blue component mismatch", sourceLocation: sourceLocation)
        #expect(abs(a - expected.3) <= Self.tolerance, "alpha component mismatch", sourceLocation: sourceLocation)
    }
}
