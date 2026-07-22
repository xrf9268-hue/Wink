import AppKit
import SwiftUI

/// Search-palette-specific panel (#356): same key-capable base as the
/// window picker, but with no `keyDown` override of its own — unlike the
/// picker, this panel hosts a real `TextField`. Keyboard routing goes
/// through SwiftUI's `.onKeyPress`/`.onSubmit` + `@FocusState` (the same
/// pattern `AppPickerPopover` already uses) once the focused field editor
/// has key status, rather than a window-level event intercept.
final class SearchPalettePanel: KeyCapableHUDPanel {}

/// Global "type an app name, press Enter, that app activates" palette
/// (#356). Reuses the #352 panel scaffolding (`KeyCapableHUDPanel`,
/// `HUDPanelPlacement`) and the exact "activate, never hide" seam
/// `AppController` wires through `activate` — see that closure's call site
/// for why a plain `toggleApplication` call would be wrong here.
///
/// State (query, highlight) lives HERE, on the controller — not as `@State`
/// inside `SearchPaletteView` — mirroring `WindowPickerHUDController`
/// exactly: every mutation goes through `renderContent()`, which rebuilds
/// the view, reassigns `hosting.rootView`, and re-measures/resizes the
/// panel via `layoutSubtreeIfNeeded()` + `fittingSize`. That's what keeps
/// the panel's height in sync as the result count changes per keystroke —
/// sizing once at `present()` and never again would clip a query that grows
/// from one row to eight. View-driven mutations (typing, arrow keys) are
/// funneled back through this controller via closures and dispatched with
/// `DispatchQueue.main.async` before touching `hosting.rootView`, since
/// reassigning it synchronously from inside a SwiftUI-owned callback (a
/// `Binding` setter, `.onKeyPress`) would mutate the same hosting view
/// while SwiftUI is still mid-update for that same view.
@MainActor
final class SearchPaletteHUDController {
    private let onSessionStateChange: @MainActor (Bool) -> Void
    /// Snapshot-at-open candidate builder — never called per keystroke. See
    /// `SearchPaletteMatcher.swift` for the latency rationale.
    private let candidatesProvider: @MainActor () -> [SearchPaletteCandidate]
    /// Most-recently-activated bundle identifiers, most recent first —
    /// orders the empty-query list; recency only, never re-scored. `nil`
    /// resolves to `[]` in the body (not a closure-literal default
    /// argument): the CI toolchain (Xcode 16.4, Swift 6.1.2) has twice
    /// crashed SILGen on non-trivial init default-argument expressions —
    /// same mitigation as `WindowCycleClient.live`/`ShortcutManager`'s
    /// `secureInputProbe`.
    private let recentBundleIdentifiersProvider: (@MainActor () -> [String])?
    private let activate: @MainActor (AppEntry) -> Bool

    /// Internal (not private) read access only — `private(set)` — so tests
    /// can assert on the panel's structural size (e.g. "grew as results
    /// grew") without opening up write access from outside the controller.
    private(set) var panel: SearchPalettePanel?
    private var hosting: NSHostingView<SearchPaletteView>?
    private var resignKeyObserver: NSObjectProtocol?
    private var isActive = false

    private var candidates: [SearchPaletteCandidate] = []
    private var recentBundleIdentifiers: [String] = []
    private var query = ""
    private var highlight = AppPickerHighlightState()

    init(
        onSessionStateChange: @escaping @MainActor (Bool) -> Void,
        candidatesProvider: @escaping @MainActor () -> [SearchPaletteCandidate],
        recentBundleIdentifiersProvider: (@MainActor () -> [String])? = nil,
        activate: @escaping @MainActor (AppEntry) -> Bool
    ) {
        self.onSessionStateChange = onSessionStateChange
        self.candidatesProvider = candidatesProvider
        self.recentBundleIdentifiersProvider = recentBundleIdentifiersProvider
        self.activate = activate
    }

    var isPresented: Bool { isActive }

    func present() {
        guard !isActive else { return }
        isActive = true
        onSessionStateChange(true)

        candidates = candidatesProvider()
        recentBundleIdentifiers = resolveRecentBundleIdentifiers()
        query = ""
        highlight.reset()

        let panel = ensurePanel()
        renderContent()
        HUDPanelPlacement.centerOnPointerScreen(panel)
        panel.makeKeyAndOrderFront(nil)

        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dismiss()
            }
        }
    }

    /// A trigger fired before `AppListProvider`'s first scan lands would
    /// otherwise open onto an empty (or installed-apps-only) snapshot that
    /// stays empty until dismiss/reopen. `AppController` calls this once the
    /// scan completes; a no-op while the palette isn't presented.
    func refreshCandidatesIfPresented() {
        guard isActive else { return }
        candidates = candidatesProvider()
        recentBundleIdentifiers = resolveRecentBundleIdentifiers()
        renderContent()
    }

    private func resolveRecentBundleIdentifiers() -> [String] {
        recentBundleIdentifiersProvider?() ?? []
    }

    func dismiss() {
        guard isActive else { return }
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
            self.resignKeyObserver = nil
        }
        isActive = false
        panel?.orderOut(nil)
        onSessionStateChange(false)
    }

    /// Empty query shows the most recently activated running apps first
    /// (Spotlight/Alfred convention), alphabetical as the tail/fallback for
    /// running apps with no recency signal; a non-empty query runs the
    /// tiered scorer. Either way this recomputes against the already-built
    /// `candidates` array, never re-scanning the app list itself (see
    /// `SearchPaletteMatcher.swift`, which owns both ranking functions).
    private var results: [SearchPaletteCandidate] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return SearchPaletteRanking.recentRunning(candidates: candidates, recentBundleIdentifiers: recentBundleIdentifiers)
        }
        return SearchPaletteRanking.rank(query: query, candidates: candidates)
    }

    private func handleQueryChange(_ newQuery: String) {
        guard query != newQuery else { return }
        query = newQuery
        highlight.searchTextChanged()
        scheduleRender()
    }

    private func moveHighlight(_ delta: Int) {
        _ = highlight.move(delta, count: results.count)
        scheduleRender()
    }

    private func commitHighlighted() {
        guard let entry = highlight.selection(in: results)?.entry else { return }
        commit(entry)
    }

    private func commit(_ entry: AppEntry) {
        // Dismiss FIRST — activation makes another app key, which fires the
        // resign-key observer; running the dismissal ourselves keeps the
        // session-state transition ordered before the activation side
        // effect (same ordering rule as WindowPickerHUDController).
        dismiss()
        _ = activate(entry)
    }

    private func ensurePanel() -> SearchPalettePanel {
        if let panel {
            return panel
        }
        let panel = SearchPalettePanel()
        self.panel = panel
        return panel
    }

    /// Defers the actual re-render/resize to the next run-loop turn: this
    /// is called from closures SwiftUI itself invokes (a `TextField`
    /// binding's setter, `.onKeyPress`), and reassigning `hosting.rootView`
    /// synchronously from inside one of those would mutate the same hosting
    /// view while SwiftUI is still mid-update for it. One tick is
    /// imperceptible; `present()`/`refreshCandidatesIfPresented()` call
    /// `renderContent()` directly since they run from plain AppKit call
    /// sites, outside any SwiftUI update.
    private func scheduleRender() {
        DispatchQueue.main.async { [weak self] in
            self?.renderContent()
        }
    }

    private func renderContent() {
        guard isActive, let panel else { return }
        let view = SearchPaletteView(
            query: query,
            results: results,
            highlightedIndex: highlight.highlightedIndex,
            onQueryChange: { [weak self] newQuery in
                self?.handleQueryChange(newQuery)
            },
            onMoveHighlight: { [weak self] delta in
                self?.moveHighlight(delta)
            },
            onCommitHighlighted: { [weak self] in
                self?.commitHighlighted()
            },
            onCommitEntry: { [weak self] entry in
                self?.commit(entry)
            },
            onCancel: { [weak self] in
                self?.dismiss()
            }
        )
        if let hosting {
            hosting.rootView = view
        } else {
            let hosting = NSHostingView(rootView: view)
            self.hosting = hosting
            panel.contentView = hosting
        }
        hosting?.layoutSubtreeIfNeeded()
        let size = hosting?.fittingSize ?? .zero
        panel.setContentSize(size)
    }
}

private enum SearchPaletteMetrics {
    static let width: CGFloat = 420
    static let maxResultsHeight: CGFloat = 320
    static let rowIconSize: CGFloat = 22
}

private struct SearchPaletteView: View {
    let query: String
    let results: [SearchPaletteCandidate]
    let highlightedIndex: Int?
    let onQueryChange: (String) -> Void
    let onMoveHighlight: (Int) -> Void
    let onCommitHighlighted: () -> Void
    let onCommitEntry: (AppEntry) -> Void
    let onCancel: () -> Void

    @FocusState private var isFieldFocused: Bool

    private var queryBinding: Binding<String> {
        Binding(get: { query }, set: { newQuery in onQueryChange(newQuery) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                WinkIcon.search.image(size: 13)
                    .foregroundStyle(.secondary)
                TextField(Self.placeholder, text: queryBinding)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($isFieldFocused)
                    .onSubmit { onCommitHighlighted() }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            if !results.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, candidate in
                                SearchPaletteRow(
                                    candidate: candidate,
                                    isHighlighted: highlightedIndex == index
                                )
                                .contentShape(Rectangle())
                                .onTapGesture { onCommitEntry(candidate.entry) }
                                .id(index)
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: SearchPaletteMetrics.maxResultsHeight)
                    .onChange(of: highlightedIndex) { _, newIndex in
                        guard let newIndex else { return }
                        proxy.scrollTo(newIndex)
                    }
                }
            } else if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Divider()
                Text(Self.noResultsText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(14)
            }
        }
        .frame(width: SearchPaletteMetrics.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear {
            isFieldFocused = true
        }
        .onKeyPress(.upArrow) { onMoveHighlight(-1); return .handled }
        .onKeyPress(.downArrow) { onMoveHighlight(1); return .handled }
        .onKeyPress(.escape) { onCancel(); return .handled }
    }

    private static var placeholder: String {
        String(localized: "Search apps…", bundle: WinkResourceBundle.bundle)
    }

    private static var noResultsText: String {
        String(localized: "No matching apps", bundle: WinkResourceBundle.bundle)
    }
}

private struct SearchPaletteRow: View {
    @Environment(\.winkPalette) private var palette

    let candidate: SearchPaletteCandidate
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(bundleIdentifier: candidate.entry.bundleIdentifier, size: SearchPaletteMetrics.rowIconSize)

            Text(candidate.entry.name)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)

            if candidate.isRunning {
                WinkStatusDot(color: palette.green)
            }

            Spacer(minLength: 8)

            if let keycap = candidate.keycap {
                Text(keycap)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHighlighted ? Color.accentColor.opacity(0.25) : .clear)
        )
    }
}
