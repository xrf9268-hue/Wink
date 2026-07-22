import AppKit
import Foundation
import SwiftUI

/// Keyboard-navigation highlight state for `AppPickerPopover`, kept as a pure
/// value type so the highlight/Return semantics are unit-testable.
struct AppPickerHighlightState {
    private(set) var highlightedIndex: Int?

    /// Highlight the first row (onAppear behavior).
    mutating func reset() {
        highlightedIndex = 0
    }

    /// A new query re-filters the list, so a retained index can point past the
    /// new bounds (Return would no-op) or at the wrong row. Re-anchor on the
    /// first visible result to match the type-ahead-then-Enter flow.
    mutating func searchTextChanged() {
        highlightedIndex = 0
    }

    /// Move the highlight by `delta`, clamped to `0..<count`. Returns the new
    /// index so the caller can scroll to it, or nil when the list is empty.
    mutating func move(_ delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let newIndex = max(0, min(count - 1, (highlightedIndex ?? 0) + delta))
        highlightedIndex = newIndex
        return newIndex
    }

    /// The highlighted entry, or nil when the index is unset or out of bounds.
    func selection<Entry>(in entries: [Entry]) -> Entry? {
        guard let highlightedIndex, entries.indices.contains(highlightedIndex) else {
            return nil
        }
        return entries[highlightedIndex]
    }
}

struct AppPickerPopover: View {
    @Environment(\.winkPalette) private var palette

    @Bindable var appListProvider: AppListProvider
    let onSelect: (AppEntry) -> Void
    let onBrowse: () -> Void

    @State private var searchText = ""
    @State private var highlight = AppPickerHighlightState()
    @Environment(\.dismiss) private var dismiss

    private var highlightedIndex: Int? { highlight.highlightedIndex }

    /// SwiftUI reads these lists several times per body render; computed
    /// properties would re-filter on each access.
    private struct Sections {
        let special: [AppEntry]
        let recent: [AppEntry]
        let nonRecent: [AppEntry]
        let all: [AppEntry]
        let flat: [AppEntry]
    }

    /// `entry.name` is locale-stable (see `AppListProvider.AppEntry.frontmostTarget`);
    /// this resolves what should actually render for a given entry, without
    /// touching the stable value selection persists.
    private func displayName(for entry: AppEntry) -> String {
        entry.bundleIdentifier == AppShortcut.frontmostTargetSentinelBundleIdentifier
            ? AppShortcut.frontmostTargetDisplayName
            : entry.name
    }

    private func computeSections() -> Sections {
        let all = appListProvider.filteredApps(query: searchText)
        guard searchText.isEmpty else {
            let special = displayName(for: AppEntry.frontmostTarget)
                .localizedCaseInsensitiveContains(searchText) ? [AppEntry.frontmostTarget] : []
            let flat = special + all
            return Sections(special: special, recent: [], nonRecent: [], all: all, flat: flat)
        }
        let special = [AppEntry.frontmostTarget]
        let recent = appListProvider.recentApps
        let recentIDs = Set(recent.map(\.bundleIdentifier))
        let nonRecent = all.filter { !recentIDs.contains($0.bundleIdentifier) }
        return Sections(special: special, recent: recent, nonRecent: nonRecent, all: all, flat: special + recent + nonRecent)
    }

    var body: some View {
        let sections = computeSections()

        // `ScrollViewReader` wraps the whole popover (not just the list) so the
        // arrow-key handlers can live on the outer VStack, an ancestor of both
        // the search TextField and the list — `.onKeyPress` only fires when the
        // modified view or a descendant holds focus, and a TextField sibling
        // doesn't qualify.
        return ScrollViewReader { proxy in
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    WinkIcon.search.image(size: 12)
                        .foregroundStyle(palette.textTertiary)
                    TextField(String(localized: "Search apps...", bundle: WinkResourceBundle.bundle), text: $searchText)
                        .textFieldStyle(.plain)
                        .font(WinkType.bodyText)
                        .foregroundStyle(palette.textPrimary)
                        .onSubmit { selectHighlighted(in: sections) }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

                Divider().overlay(palette.hairline)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if searchText.isEmpty {
                            ForEach(Array(sections.special.enumerated()), id: \.element.id) { index, entry in
                                appRow(entry, index: index)
                            }

                            if !sections.recent.isEmpty {
                                WinkSectionLabel(String(localized: "Recently Used", bundle: WinkResourceBundle.bundle))
                                    .padding(.horizontal, 14)
                                    .padding(.top, 8)
                                    .padding(.bottom, 4)
                                ForEach(Array(sections.recent.enumerated()), id: \.element.id) { i, entry in
                                    appRow(entry, index: sections.special.count + i)
                                }
                            }

                            if !sections.nonRecent.isEmpty {
                                WinkSectionLabel(String(localized: "All Apps", bundle: WinkResourceBundle.bundle))
                                    .padding(.horizontal, 14)
                                    .padding(.top, 8)
                                    .padding(.bottom, 4)
                                ForEach(Array(sections.nonRecent.enumerated()), id: \.element.id) { i, entry in
                                    let index = sections.special.count + sections.recent.count + i
                                    appRow(entry, index: index)
                                }
                            }
                        } else {
                            ForEach(Array(sections.flat.enumerated()), id: \.element.id) { index, entry in
                                appRow(entry, index: index)
                            }
                        }
                    }
                }
                // `.onSubmit` on the search TextField already handles Return
                // while typing; keep this scoped to the list so a highlighted
                // row doesn't fire selection twice.
                .onKeyPress(.return) { selectHighlighted(in: sections); return .handled }

                Divider().overlay(palette.hairline)

                Button {
                    onBrowse()
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: "folder")
                        Text("Browse...", bundle: WinkResourceBundle.bundle)
                    }
                    .font(WinkType.labelSmall)
                    .foregroundStyle(palette.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
            .frame(width: 320, height: 400)
            .onAppear {
                appListProvider.refreshIfNeeded()
                highlight.reset()
            }
            .onChange(of: searchText) {
                highlight.searchTextChanged()
            }
            .onKeyPress(.upArrow) { moveHighlight(-1, proxy: proxy, in: sections); return .handled }
            .onKeyPress(.downArrow) { moveHighlight(1, proxy: proxy, in: sections); return .handled }
            .onKeyPress(.escape) { dismiss(); return .handled }
        }
    }

    // MARK: - Subviews

    private func appRow(_ entry: AppEntry, index: Int) -> some View {
        Button {
            select(entry)
        } label: {
            HStack(spacing: 10) {
                AppIconView(bundleIdentifier: entry.bundleIdentifier, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(displayName(for: entry))
                        .font(highlightedIndex == index ? WinkType.bodyMedium : WinkType.bodyText)
                        .foregroundStyle(palette.textPrimary)
                    Text(entry.bundleIdentifier)
                        .font(.system(size: 10))
                        .foregroundStyle(palette.textTertiary)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(highlightedIndex == index ? palette.accentBgSoft : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .id(index)
    }

    // MARK: - Navigation

    private func moveHighlight(_ delta: Int, proxy: ScrollViewProxy, in sections: Sections) {
        guard let newIndex = highlight.move(delta, count: sections.flat.count) else { return }
        proxy.scrollTo(newIndex, anchor: .center)
    }

    private func selectHighlighted(in sections: Sections) {
        guard let entry = highlight.selection(in: sections.flat) else { return }
        select(entry)
    }

    private func select(_ entry: AppEntry) {
        // The pinned Current App entry is not a real app: recording it as
        // recent would evict a genuine recent (the recents list silently
        // drops ids missing from the app catalog).
        if entry.bundleIdentifier != AppShortcut.frontmostTargetSentinelBundleIdentifier {
            appListProvider.noteRecentApp(bundleIdentifier: entry.bundleIdentifier)
        }
        onSelect(entry)
        dismiss()
    }
}
