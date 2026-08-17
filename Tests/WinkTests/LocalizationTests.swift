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

    /// Every `String(localized:)` / `Text(_:bundle:)` call site must name a key
    /// the catalog actually ships.
    ///
    /// The per-feature tests in this file assert that a hand-listed key
    /// resolves — which cannot catch a *call site* whose key was never added,
    /// or one that drifted a character away from the entry written for it.
    /// Both had shipped: the Manage Profiles sheet's Rename/Delete/Done
    /// buttons had no catalog entries at all, and the Focus banner asked for
    /// `Focus is using “%@”` while the catalog held `Focus is using “%@”.`
    /// with a trailing period. All four rendered in English for Chinese users
    /// with every test in this file green.
    @Test
    func everyCatalogCallSiteHasAKey() throws {
        let known = Set(try catalogKeys().map(Self.canonicalized))
        var orphans: [String] = []

        for file in try swiftSources() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for site in Self.catalogCallSites(in: text)
            where !known.contains(Self.canonicalized(site.key)) {
                orphans.append("\(file.lastPathComponent):\(site.line)  \(site.key)")
            }
        }

        #expect(
            orphans.isEmpty,
            """
            These call sites ask for a key the String Catalog does not have, \
            so they render their English literal in every locale. Add the key \
            to Sources/Wink/Resources/Localizable.xcstrings and run \
            scripts/gen-localizations.sh:
            \(orphans.sorted().joined(separator: "\n"))
            """
        )
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
            // No trailing period: banner titles in this UI do not take one,
            // and the catalog's periodful variant matched no call site at all
            // — this list pinned a key the app never looked up, so the banner
            // rendered in English while the test stayed green. See
            // `everyCatalogCallSiteHasAKey`, which now catches that class.
            "Focus is using “%@”",
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
        //
        // These single-letter keys are also why brand marks must use
        // `Text(verbatim:)`: a bare `Text("W")` anywhere in the app resolves
        // through this catalog and renders 周. That is exactly how the
        // wordmark shipped as "周ink" — see `WinkWordmark`.
        let sub = try subBundle(forLocalization: "zh-Hans")
        #expect(sub.localizedString(forKey: "D", value: "«miss»", table: nil) == "日")
        #expect(sub.localizedString(forKey: "W", value: "«miss»", table: nil) == "周")
        #expect(sub.localizedString(forKey: "M", value: "«miss»", table: nil) == "月")
    }

    // MARK: - Call-site scanning

    private struct CatalogCallSite {
        let key: String
        let line: Int
    }

    /// Interpolations and format placeholders both collapse to one sentinel,
    /// so `"Imported \(count) shortcuts"` matches the catalog's
    /// `"Imported %lld shortcuts"` without the test having to infer which
    /// specifier the compiler picked.
    ///
    /// Known limit, accepted: because `%@` and `%lld` collapse together, this
    /// scan cannot see a call site whose interpolation changed *type* while
    /// the catalog kept the old specifier. Telling those apart needs the
    /// interpolation's Swift type, which a lexical scan does not have. The
    /// check is scoped to what it can prove — that a key exists at all.
    private static let placeholder: Character = "\u{1}"

    private static func canonicalized(_ key: String) -> String {
        var out = ""
        var rest = Substring(key)
        while let percent = rest.firstIndex(of: "%") {
            out.append(contentsOf: rest[rest.startIndex..<percent])
            var i = rest.index(after: percent)
            if i < rest.endIndex, rest[i] == "%" {          // literal "%%"
                out.append("%")
                rest = rest[rest.index(after: i)...]
                continue
            }
            while i < rest.endIndex, !"@dfsl".contains(rest[i]) { i = rest.index(after: i) }
            while i < rest.endIndex, "dfsl".contains(rest[i]) { i = rest.index(after: i) }
            if i < rest.endIndex, rest[i] == "@" { i = rest.index(after: i) }
            out.append(placeholder)
            rest = rest[i...]
        }
        out.append(contentsOf: rest)
        return out
    }

    /// The literal always follows one of these labels, but not always on the
    /// same line — `Text(\n    "…",\n    bundle: …)` is common in this
    /// codebase, so the scan skips whitespace before demanding the quote.
    /// Anchoring on `Text("` instead silently skipped six live call sites.
    ///
    /// A trigger that is not followed by a string literal (`Text(verbatim:)`,
    /// `Text(someVariable)`, the words `String(localized:)` inside prose) just
    /// fails the quote check and is dropped.
    private static let triggers = ["localized:", "Text("]

    private static func catalogCallSites(in text: String) -> [CatalogCallSite] {
        let chars = Array(text)
        var sites: [CatalogCallSite] = []

        for trigger in triggers {
            let pattern = Array(trigger)
            var start = 0
            while let hit = index(of: pattern, in: chars, from: start) {
                start = hit + pattern.count

                var quote = hit + pattern.count
                while quote < chars.count, chars[quote].isWhitespace { quote += 1 }
                guard quote < chars.count, chars[quote] == "\"" else { continue }
                guard let literal = readLiteral(chars, from: quote) else { continue }

                // Only call sites that route through the app's catalog: a
                // literal without `bundle:` is not a catalog lookup at all.
                let tailEnd = min(literal.end + 80, chars.count)
                let tail = String(chars[literal.end..<tailEnd])
                guard tail.contains("bundle:") else { continue }
                sites.append(
                    CatalogCallSite(
                        key: literal.key,
                        line: chars[0..<hit].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
                    )
                )
            }
        }
        return sites
    }

    private static func index(of pattern: [Character], in chars: [Character], from: Int) -> Int? {
        guard pattern.count <= chars.count else { return nil }
        var i = from
        while i <= chars.count - pattern.count {
            if Array(chars[i..<(i + pattern.count)]) == pattern { return i }
            i += 1
        }
        return nil
    }

    /// `chars[quote]` is the opening quote. Returns nil for anything this
    /// simple reader cannot state with confidence (multi-line or raw strings),
    /// which is a skipped call site, never a false failure.
    private static func readLiteral(
        _ chars: [Character],
        from quote: Int
    ) -> (key: String, end: Int)? {
        var key = ""
        var i = quote + 1
        while i < chars.count {
            switch chars[i] {
            case "\\":
                guard i + 1 < chars.count else { return nil }
                if chars[i + 1] == "(" {
                    var depth = 1
                    i += 2
                    while i < chars.count, depth > 0 {
                        if chars[i] == "(" { depth += 1 }
                        if chars[i] == ")" { depth -= 1 }
                        i += 1
                    }
                    key.append(placeholder)
                } else {
                    key.append(["n": "\n", "t": "\t", "\"": "\"", "\\": "\\"][chars[i + 1]] ?? chars[i + 1])
                    i += 2
                }
            case "\"":
                return (key, i + 1)
            case "\n":
                return nil
            default:
                key.append(chars[i])
                i += 1
            }
        }
        return nil
    }

    private func swiftSources() throws -> [URL] {
        let root = repoRoot.appending(path: "Sources/Wink")
        let all = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return (all?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }

    /// English is the source language, so its compiled table holds every key
    /// the catalog defines.
    ///
    /// Deliberately the **default table only**. `AppShortcuts.strings` is a
    /// separate table reached solely through App Intents phrase declarations,
    /// never through the call sites this scan finds; unioning it in would let
    /// a default-table lookup pass because the key happens to exist in a table
    /// that lookup will never consult. `appShortcutPhrasesPreserveTheApplicationToken`
    /// covers that table on its own.
    ///
    /// Both file types are required: a catalog entry with plural variations
    /// compiles into `.stringsdict` and is absent from `.strings` entirely, so
    /// reading only the latter reports live plural keys as orphans.
    private func catalogKeys() throws -> [String] {
        var keys: [String] = []
        let localized = repoRoot.appending(path: "Sources/Wink/Resources/Localized/en.lproj")

        let url = localized.appending(path: "Localizable.strings")
        let dictionary = try #require(
            NSDictionary(contentsOf: url) as? [String: Any],
            "could not read \(url.lastPathComponent) — run scripts/gen-localizations.sh"
        )
        keys.append(contentsOf: dictionary.keys)

        let plurals = localized.appending(path: "Localizable.stringsdict")
        if let plurals = NSDictionary(contentsOf: plurals) as? [String: Any] {
            keys.append(contentsOf: plurals.keys)
        }
        return keys
    }
}

private let repoRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
