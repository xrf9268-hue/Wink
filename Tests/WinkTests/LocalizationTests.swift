import Foundation
import Testing
@testable import Wink

/// Verifies the compiled Localizable.strings/.stringsdict catalog actually
/// resolves from the resource bundle — swift build/test never compile
/// Localizable.xcstrings itself (see scripts/gen-localizations.sh); this
/// guards against the checked-in Sources/Wink/Resources/Localized output
/// drifting out of sync or silently failing to load.
@Suite("Localization catalog")
struct LocalizationTests {
    /// Deterministic per-locale lookup, independent of the host machine's
    /// language settings: resolve a locale-specific sub-bundle directly
    /// instead of relying on the process's current preferred language.
    private func subBundle(forLocalization localization: String) throws -> Bundle {
        let bundle = WinkResourceBundle.bundle
        let path = try #require(
            bundle.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: localization)
        )
        return try #require(Bundle(path: (path as NSString).deletingLastPathComponent))
    }

    @Test
    func zhHansResolvesAKnownKey() throws {
        let sub = try subBundle(forLocalization: "zh-Hans")
        #expect(sub.localizedString(forKey: "Ready", value: "«miss»", table: nil) == "就绪")
    }

    @Test
    func enResolvesTheSameKeyToEnglish() throws {
        let sub = try subBundle(forLocalization: "en")
        #expect(sub.localizedString(forKey: "Ready", value: "«miss»", table: nil) == "Ready")
    }

    @Test
    func zhHansResolvesAFormatKey() throws {
        let sub = try subBundle(forLocalization: "zh-Hans")
        let format = sub.localizedString(forKey: "Paused · %@", value: "«miss»", table: nil)
        #expect(format == "已暂停 · %@")
        #expect(String(format: format, "Zoom") == "已暂停 · Zoom")
    }

    @Test
    func zhHansResolvesAPluralKeyViaStringsdict() throws {
        let sub = try subBundle(forLocalization: "zh-Hans")
        let key = "%lld standard shortcut bindings failed to register. Check logs for the blocked key combinations."
        // zh-Hans has no plural forms — a single stringUnit covers every count.
        let one = String.localizedStringWithFormat(sub.localizedString(forKey: key, value: "«miss»", table: nil), 1)
        let many = String.localizedStringWithFormat(sub.localizedString(forKey: key, value: "«miss»", table: nil), 5)
        #expect(one.contains("1"))
        #expect(many.contains("5"))
        #expect(one.contains("标准快捷键绑定注册失败"))
        #expect(many.contains("标准快捷键绑定注册失败"))
    }

    @Test
    func enResolvesThePluralKeyWithOneVersusOtherWording() throws {
        // The en catalog does carry a genuine one/other split (unlike
        // zh-Hans); the "activations" plural is the clearest example, and it
        // goes through the compiled .stringsdict via NSString(format:).
        let sub = try subBundle(forLocalization: "en")
        let format = sub.localizedString(forKey: "%lld activations", value: "«miss»", table: nil)
        let one = String(format: format, locale: Locale(identifier: "en_US"), 1)
        let many = String(format: format, locale: Locale(identifier: "en_US"), 5)
        #expect(one == "1 activation")
        #expect(many == "5 activations")
    }

    @Test
    func preferredLocalizationsPickZhHansForZhCNPreference() {
        // SPM lowercases lproj directory names in the built resource bundle
        // (zh-hans.lproj), so `bundle.localizations` reports "zh-hans" rather
        // than "zh-Hans" — Foundation's locale matcher is documented to
        // tolerate this, so assert case-insensitively rather than "fixing"
        // the casing.
        let bundle = WinkResourceBundle.bundle
        let preferred = Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: ["zh-CN"])
        #expect(preferred.first?.lowercased() == "zh-hans")
    }

    @Test
    func catalogDeclaresBothShippedLocalizations() {
        let bundle = WinkResourceBundle.bundle
        #expect(Set(bundle.localizations.map { $0.lowercased() }) == ["en", "zh-hans"])
    }

    @Test
    func frontmostTargetDisplayNameIsLocalized() throws {
        // AppShortcut.frontmostTargetDisplayName resolves through
        // WinkResourceBundle at access time; confirm the zh-Hans string
        // used to build that lookup is present and correct.
        let sub = try subBundle(forLocalization: "zh-Hans")
        #expect(sub.localizedString(forKey: "Current App", value: "«miss»", table: nil) == "当前应用")
    }
}
