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
    static let entries: [String: [WhatsNewNote]] = [
        "0.6.0": [
            WhatsNewNote(
                symbolName: "arrow.down.circle",
                title: "Updates, the Wink way",
                detail: "Checking, download progress, and installs now happen right here — no more separate update dialogs."
            ),
            WhatsNewNote(
                symbolName: "switch.2",
                title: "Automatic updates, your call",
                detail: "The Settings toggle is live: background checks and downloads, on or off."
            ),
            WhatsNewNote(
                symbolName: "bolt",
                title: "Snappier shortcuts",
                detail: "Less work between keypress and app switch, especially with minimized windows."
            ),
        ],
        "0.5.0": [
            WhatsNewNote(
                symbolName: "keyboard",
                title: "Toggle apps with global shortcuts",
                detail: "Press once to open or focus the target app, press again to hide it."
            ),
            WhatsNewNote(
                symbolName: "capslock",
                title: "Hyper key path",
                detail: "Hold Caps Lock as a Hyper modifier alongside normal shortcut combos."
            ),
            WhatsNewNote(
                symbolName: "square.and.arrow.up",
                title: "Shareable shortcut sets",
                detail: "Import and export .winkrecipe files, with usage insights in Settings."
            ),
        ],
    ]

    static func notes(for version: String) -> [WhatsNewNote] {
        entries[version] ?? []
    }
}
