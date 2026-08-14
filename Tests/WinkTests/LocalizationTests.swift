import Foundation
import Testing
@testable import Wink

/// Verifies the compiled Localizable.strings/.stringsdict catalog actually
/// resolves from the resource bundle — swift build/test never compile
/// the .xcstrings sources themselves (see scripts/gen-localizations.sh); this
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
    func appShortcutPhrasesPreserveTheApplicationTokenInBothLocales() throws {
        let keys = [
            "Pause ${applicationName}",
            "Resume ${applicationName}",
            "Search with ${applicationName}",
            "Open ${applicationName} settings",
        ]

        for locale in ["en", "zh-Hans"] {
            let bundle = try subBundle(forLocalization: locale)
            for key in keys {
                let localized = bundle.localizedString(
                    forKey: key,
                    value: "«miss»",
                    table: "AppShortcuts"
                )
                #expect(localized != "«miss»", "missing \(locale) App Shortcut phrase: \(key)")
                #expect(localized.contains("${applicationName}"))
            }
        }
    }

    @Test
    func zhHansResolvesAKnownKey() throws {
        let sub = try subBundle(forLocalization: "zh-Hans")
        #expect(sub.localizedString(forKey: "Ready", value: "«miss»", table: nil) == "就绪")
    }

    @Test
    func appIntentResultsAndFailuresResolveInZhHans() throws {
        let sub = try subBundle(forLocalization: "zh-Hans")
        let keys = [
            "Wink manual pause is cleared.",
            "Wink could not pause shortcuts.",
            "Wink could not resume shortcuts.",
            "Wink could not show the Search Palette.",
            "Wink Settings is not ready yet. Please try again.",
            "Wink Settings did not become visible.",
        ]

        for key in keys {
            let translated = sub.localizedString(forKey: key, value: "«miss»", table: nil)
            #expect(translated != "«miss»", "missing zh-Hans App Intent entry for \(key)")
            #expect(translated != key, "zh-Hans App Intent entry for \(key) is still English")
        }
    }

    @Test
    func enResolvesTheSameKeyToEnglish() throws {
        let sub = try subBundle(forLocalization: "en")
        #expect(sub.localizedString(forKey: "Ready", value: "«miss»", table: nil) == "Ready")
    }

    /// Profile strings are the newest surface and the easiest to get wrong:
    /// a key that does not match the catalog falls back to the literal
    /// English silently, so nothing fails — the UI just stops being
    /// translated. Every interpolated key is included, because those are the
    /// ones whose `%@`/`%lld` shape has to match what Swift generates from
    /// the interpolation.
    @Test
    func zhHansResolvesEveryProfileKeyIncludingTheInterpolatedOnes() throws {
        let sub = try subBundle(forLocalization: "zh-Hans")
        let keys = [
            "Profile",
            "Manage Profiles",
            "Duplicate current profile",
            "New empty profile",
            "Recover",
            "Keep this profile",
            "Wink could not read your profile list",
            "shortcuts.json was changed outside Wink",
            "Recipes import into the active profile. Profiles stay on this Mac; recipes are how you share bindings.",
            // Interpolated keys.
            "%@ copy",
            "%@ copy %lld",
            "%@ (can't be read)",
            "“%@” could not be read",
            "Import into “%@”",
            "Created the profile “%@”.",
            "Delete “%@”?",
            "A copy of the unreadable file was saved to %@.",
            "You can have at most %lld profiles.",
            "Profile names can be at most %lld characters.",
        ]

        for key in keys {
            let translated = sub.localizedString(forKey: key, value: "«miss»", table: nil)
            #expect(translated != "«miss»", "missing zh-Hans entry for \(key)")
            #expect(translated != key, "zh-Hans entry for \(key) is still English")
        }
    }

    @Test
    func profileFormatKeysKeepTheirPlaceholdersInZhHans() throws {
        let sub = try subBundle(forLocalization: "zh-Hans")

        let copyFormat = sub.localizedString(forKey: "%@ copy", value: "«miss»", table: nil)
        #expect(String(format: copyFormat, "Work") == "Work 副本")

        let numberedCopy = sub.localizedString(forKey: "%@ copy %lld", value: "«miss»", table: nil)
        #expect(String.localizedStringWithFormat(numberedCopy, "Work", 3).contains("3"))

        let limit = sub.localizedString(forKey: "You can have at most %lld profiles.", value: "«miss»", table: nil)
        #expect(String.localizedStringWithFormat(limit, ShortcutProfileManifest.maximumProfileCount).contains("32"))
    }

    @Test
    func zhHansResolvesFocusFilterStateAndRecoveryCopy() throws {
        let sub = try subBundle(forLocalization: "zh-Hans")
        let keys = [
            "Focus Filter",
            "%@ (Focus pending)",
            "Paused · Focus",
            "Shortcuts paused by Focus",
            "Shortcuts paused by Focus and another reason",
            "Change or deactivate the Focus Filter, then clear the remaining pause reason before shortcut capture can resume.",
            "Wink · Paused",
            "Focus is using “%@”.",
            "Focus ended and Wink restored “%@”.",
            "%@ (restore after Focus)",
            "The active Focus Filter refers to a profile that no longer exists. Wink kept the current profile instead of choosing another one.",
            "Wink cannot access its Focus Filter shared container. The app and extension must be signed with the same App Group entitlement.",
            "This Wink Focus Filter data uses unsupported schema version %lld.",
        ]

        for key in keys {
            let translated = sub.localizedString(forKey: key, value: "«miss»", table: nil)
            #expect(translated != "«miss»", "missing zh-Hans Focus Filter entry for \(key)")
            #expect(translated != key, "zh-Hans Focus Filter entry for \(key) is still English")
        }
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
