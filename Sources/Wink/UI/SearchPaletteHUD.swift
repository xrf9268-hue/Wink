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
@MainActor
final class SearchPaletteHUDController {
    private let onSessionStateChange: @MainActor (Bool) -> Void
    /// Snapshot-at-open candidate builder — never called per keystroke. See
    /// `SearchPaletteMatcher.swift` for the latency rationale.
    private let candidatesProvider: @MainActor () -> [SearchPaletteCandidate]
    private let activate: @MainActor (AppEntry) -> Bool

    private var panel: SearchPalettePanel?
    private var hosting: NSHostingView<SearchPaletteView>?
    private var resignKeyObserver: NSObjectProtocol?
    private var isActive = false

    init(
        onSessionStateChange: @escaping @MainActor (Bool) -> Void,
        candidatesProvider: @escaping @MainActor () -> [SearchPaletteCandidate],
        activate: @escaping @MainActor (AppEntry) -> Bool
    ) {
        self.onSessionStateChange = onSessionStateChange
        self.candidatesProvider = candidatesProvider
        self.activate = activate
    }

    var isPresented: Bool { isActive }

    func present() {
        guard !isActive else { return }
        isActive = true
        onSessionStateChange(true)

        let candidates = candidatesProvider()
        let panel = ensurePanel()
        render(candidates: candidates)
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

    private func render(candidates: [SearchPaletteCandidate]) {
        guard let panel else { return }
        let view = SearchPaletteView(
            candidates: candidates,
            onCommit: { [weak self] entry in
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
    let candidates: [SearchPaletteCandidate]
    let onCommit: (AppEntry) -> Void
    let onCancel: () -> Void

    @State private var query = ""
    @State private var highlight = AppPickerHighlightState()
    @FocusState private var isFieldFocused: Bool

    /// Empty query shows the most recent apps up front (Spotlight/Alfred
    /// convention) — cheap since `AppListProvider` already tracks recency;
    /// a non-empty query runs the tiered scorer. Either way this recomputes
    /// per keystroke against the already-built `candidates` array, never
    /// re-scanning the app list itself (see `SearchPaletteMatcher.swift`).
    private var results: [SearchPaletteCandidate] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Array(candidates.filter(\.isRunning).prefix(SearchPaletteRanking.defaultLimit))
        }
        return SearchPaletteRanking.rank(query: query, candidates: candidates)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                WinkIcon.search.image(size: 13)
                    .foregroundStyle(.secondary)
                TextField(Self.placeholder, text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($isFieldFocused)
                    .onSubmit { commitHighlighted() }
                    .onChange(of: query) { _, _ in
                        highlight.searchTextChanged()
                    }
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
                                    isHighlighted: highlight.highlightedIndex == index
                                )
                                .contentShape(Rectangle())
                                .onTapGesture { onCommit(candidate.entry) }
                                .id(index)
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: SearchPaletteMetrics.maxResultsHeight)
                    .onChange(of: highlight.highlightedIndex) { _, newIndex in
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
            highlight.reset()
            isFieldFocused = true
        }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.escape) { onCancel(); return .handled }
    }

    private func move(_ delta: Int) {
        _ = highlight.move(delta, count: results.count)
    }

    private func commitHighlighted() {
        guard let entry = highlight.selection(in: results)?.entry else { return }
        onCommit(entry)
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
