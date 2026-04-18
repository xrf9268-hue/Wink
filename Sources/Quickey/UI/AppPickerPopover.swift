import AppKit
import SwiftUI

struct AppPickerPopover: View {
    @Bindable var appListProvider: AppListProvider
    let onSelect: (AppEntry) -> Void
    let onBrowse: () -> Void

    @State private var searchText = ""
    @State private var highlightedIndex: Int?
    @Environment(\.dismiss) private var dismiss

    /// SwiftUI reads these lists several times per body render; computed
    /// properties would re-filter on each access.
    private struct Sections {
        let recent: [AppEntry]
        let nonRecent: [AppEntry]
        let all: [AppEntry]
        let flat: [AppEntry]
    }

    private func computeSections() -> Sections {
        let all = appListProvider.filteredApps(query: searchText)
        guard searchText.isEmpty else {
            return Sections(recent: [], nonRecent: [], all: all, flat: all)
        }
        let recent = appListProvider.recentApps
        let recentIDs = Set(recent.map(\.bundleIdentifier))
        let nonRecent = all.filter { !recentIDs.contains($0.bundleIdentifier) }
        return Sections(recent: recent, nonRecent: nonRecent, all: all, flat: recent + nonRecent)
    }

    var body: some View {
        let sections = computeSections()
        return VStack(spacing: 0) {
            // Search field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                TextField("Search apps...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit { selectHighlighted(in: sections) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            // Scrollable list with keyboard nav
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if searchText.isEmpty {
                            if !sections.recent.isEmpty {
                                sectionHeader("Recently Used")
                                ForEach(Array(sections.recent.enumerated()), id: \.element.id) { index, entry in
                                    appRow(entry, index: index, proxy: proxy)
                                }
                            }

                            if !sections.nonRecent.isEmpty {
                                sectionHeader("All Apps")
                                ForEach(Array(sections.nonRecent.enumerated()), id: \.element.id) { i, entry in
                                    let index = sections.recent.count + i
                                    appRow(entry, index: index, proxy: proxy)
                                }
                            }
                        } else {
                            ForEach(Array(sections.all.enumerated()), id: \.element.id) { index, entry in
                                appRow(entry, index: index, proxy: proxy)
                            }
                        }
                    }
                }
                .onKeyPress(.upArrow) { moveHighlight(-1, proxy: proxy, in: sections); return .handled }
                .onKeyPress(.downArrow) { moveHighlight(1, proxy: proxy, in: sections); return .handled }
                .onKeyPress(.return) { selectHighlighted(in: sections); return .handled }
            }

            Divider()

            // Browse fallback
            Button {
                onBrowse()
                dismiss()
            } label: {
                HStack {
                    Image(systemName: "folder")
                    Text("Browse...")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
        }
        .frame(width: 320, height: 400)
        .onAppear {
            appListProvider.refreshIfNeeded()
            highlightedIndex = 0
        }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    // MARK: - Subviews

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .tracking(0.5)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    private func appRow(_ entry: AppEntry, index: Int, proxy: ScrollViewProxy) -> some View {
        Button {
            select(entry)
        } label: {
            HStack(spacing: 10) {
                AppIconView(bundleIdentifier: entry.bundleIdentifier, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name)
                        .font(.system(size: 13, weight: highlightedIndex == index ? .medium : .regular))
                    Text(entry.bundleIdentifier)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(highlightedIndex == index ? Color.accentColor.opacity(0.15) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .id(index)
    }

    // MARK: - Navigation

    private func moveHighlight(_ delta: Int, proxy: ScrollViewProxy, in sections: Sections) {
        let count = sections.flat.count
        guard count > 0 else { return }
        let current = highlightedIndex ?? 0
        let newIndex = max(0, min(count - 1, current + delta))
        highlightedIndex = newIndex
        proxy.scrollTo(newIndex, anchor: .center)
    }

    private func selectHighlighted(in sections: Sections) {
        guard let index = highlightedIndex, index < sections.flat.count else { return }
        select(sections.flat[index])
    }

    private func select(_ entry: AppEntry) {
        appListProvider.noteRecentApp(bundleIdentifier: entry.bundleIdentifier)
        onSelect(entry)
        dismiss()
    }
}
