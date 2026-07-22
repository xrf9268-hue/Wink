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

    /// AppEntry.frontmostTarget.name is exactly what `ShortcutsTabView`'s
    /// picker `onSelect` copies into `ShortcutEditorState.selectedAppName`,
    /// which `addShortcut()` then persists verbatim as the new shortcut's
    /// `appName` — this is the actual "new pseudo-target shortcut" data
    /// path, not just a constant comparison. It must resolve to the plain
    /// English literal "Current App" (`frontmostTargetStableName`), never
    /// the localized `frontmostTargetDisplayName`, regardless of what the
    /// catalog's zh-Hans translation says — shortcuts.json / exported
    /// .winkrecipe content must not depend on the active system language
    /// (#323's locale-stable-persistence principle).
    @Test
    func newPseudoTargetShortcutPersistsTheStableNameNotTheLocalizedLabel() {
        #expect(AppShortcut.frontmostTargetStableName == "Current App")
        #expect(AppEntry.frontmostTarget.name == "Current App")

        let persisted = AppShortcut(
            appName: AppEntry.frontmostTarget.name,
            bundleIdentifier: AppEntry.frontmostTarget.bundleIdentifier,
            keyEquivalent: "j",
            modifierFlags: ["command"],
            target: .frontmostApp
        )
        #expect(persisted.appName == "Current App")

        // WinkRecipeImportPlanner's resolvedAppName for an imported
        // frontmost-app row must be the same stable value (see
        // PerShortcutBehaviorOverrideTests.recipeWithFrontmostTargetExportsAsV2AndPlansAvailable
        // for the full encode/decode/import round trip).
        #expect(AppShortcut.frontmostTargetStableName == AppEntry.frontmostTarget.name)
    }

    /// Display sites must resolve a pseudo-target row's name through
    /// `displayAppName`, independent of whatever stable string is actually
    /// stored in `appName`.
    @Test
    func displayAppNameLocalizesSentinelRowsButPassesOtherAppsThrough() {
        let pseudo = AppShortcut(
            appName: AppShortcut.frontmostTargetStableName,
            bundleIdentifier: AppShortcut.frontmostTargetSentinelBundleIdentifier,
            keyEquivalent: "j",
            modifierFlags: ["command"],
            target: .frontmostApp
        )
        #expect(pseudo.appName == "Current App")
        #expect(pseudo.displayAppName == AppShortcut.frontmostTargetDisplayName)

        let regular = AppShortcut(
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            keyEquivalent: "s",
            modifierFlags: ["command"]
        )
        #expect(regular.displayAppName == "Safari")
    }

    @Test
    func zhHansResolvesTheInsightsPeriodSegmentLabels() throws {
        // The segmented control's rawValue ("D"/"W"/"M") stays a plain
        // Latin option identifier; InsightsPeriod.segmentLabel is the
        // localized on-screen label and must resolve to the Screen
        // Time-style abbreviations in zh-Hans.
        let sub = try subBundle(forLocalization: "zh-Hans")
        #expect(sub.localizedString(forKey: "D", value: "«miss»", table: nil) == "日")
        #expect(sub.localizedString(forKey: "W", value: "«miss»", table: nil) == "周")
        #expect(sub.localizedString(forKey: "M", value: "«miss»", table: nil) == "月")
    }
}
