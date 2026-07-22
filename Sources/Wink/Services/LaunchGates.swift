import Foundation

/// Pure launch-time decision for the post-update "What's New" surface.
///
/// Semantics (mirrors the PomoFox `LaunchGates` reference):
/// - Fresh installs never see What's New — the first launch only records the
///   version.
/// - A later launch shows it exactly once when the version changed since the
///   last recorded one and that version has notes. `lastSeenVersion == nil`
///   on an already-onboarded install (upgrade from a pre-feature build)
///   counts as changed — the user did just update.
///
/// The caller is responsible for writing back `lastSeenVersion` after
/// deciding (see `AppController.consumeWhatsNewGate`).
enum LaunchGates {
    static func shouldShowWhatsNew(
        currentVersion: String,
        hasLaunchedBefore: Bool,
        lastSeenVersion: String?,
        hasNotes: Bool
    ) -> Bool {
        guard hasLaunchedBefore else { return false }
        return lastSeenVersion != currentVersion && hasNotes
    }
}

/// One highlighted change in a release, rendered in the What's New panel.
struct WhatsNewNote: Equatable, Sendable {
    /// SF Symbol name.
    let symbolName: String
    let title: String
    let detail: String
}

/// Version → curated highlights. Versions without an entry never present a
/// What's New panel (the gate's `hasNotes` input). Keep entries short — the
/// full notes live on the GitHub Releases page the panel links to; the
/// authoritative prose is CHANGELOG.md.
enum WhatsNewCatalog {
    // Built lazily (not a `static let` literal) because each note's title/detail
    // is a localized lookup, resolved against the current locale at access time
    // rather than baked in at first process launch.
    private static func entries() -> [String: [WhatsNewNote]] {
        [
            "0.6.0": [
                WhatsNewNote(
                    symbolName: "arrow.down.circle",
                    title: String(localized: "Updates, the Wink way", bundle: WinkResourceBundle.bundle),
                    detail: String(
                        localized: "Checking, download progress, and installs now happen right here — no more separate update dialogs.",
                        bundle: WinkResourceBundle.bundle
                    )
                ),
                WhatsNewNote(
                    symbolName: "switch.2",
                    title: String(localized: "Automatic updates, your call", bundle: WinkResourceBundle.bundle),
                    detail: String(
                        localized: "The Settings toggle is live: background checks and downloads, on or off.",
                        bundle: WinkResourceBundle.bundle
                    )
                ),
                WhatsNewNote(
                    symbolName: "bolt",
                    title: String(localized: "Snappier shortcuts", bundle: WinkResourceBundle.bundle),
                    detail: String(
                        localized: "Less work between keypress and app switch, especially with minimized windows.",
                        bundle: WinkResourceBundle.bundle
                    )
                ),
            ],
            "0.5.0": [
                WhatsNewNote(
                    symbolName: "keyboard",
                    title: String(localized: "Toggle apps with global shortcuts", bundle: WinkResourceBundle.bundle),
                    detail: String(
                        localized: "Press once to open or focus the target app, press again to hide it.",
                        bundle: WinkResourceBundle.bundle
                    )
                ),
                WhatsNewNote(
                    symbolName: "capslock",
                    title: String(localized: "Hyper key path", bundle: WinkResourceBundle.bundle),
                    detail: String(
                        localized: "Hold Caps Lock as a Hyper modifier alongside normal shortcut combos.",
                        bundle: WinkResourceBundle.bundle
                    )
                ),
                WhatsNewNote(
                    symbolName: "square.and.arrow.up",
                    title: String(localized: "Shareable shortcut sets", bundle: WinkResourceBundle.bundle),
                    detail: String(
                        localized: "Import and export .winkrecipe files, with usage insights in Settings.",
                        bundle: WinkResourceBundle.bundle
                    )
                ),
            ],
        ]
    }

    static func notes(for version: String) -> [WhatsNewNote] {
        entries()[version] ?? []
    }
}
