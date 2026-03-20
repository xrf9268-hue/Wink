import AppKit
import SwiftUI

struct AppPickerPopover: View {
    @Bindable var appListProvider: AppListProvider
    let onSelect: (AppEntry) -> Void
    let onBrowse: () -> Void

    @State private var searchText = ""
    @State private var highlightedIndex: Int?
    @Environment(\.dismiss) private var dismiss

    private var filteredRecent: [AppEntry] {
        if searchText.isEmpty {
            return appListProvider.recentApps
        }
        return []
    }

    private var filteredAll: [AppEntry] {
        appListProvider.filteredApps(query: searchText)
    }

    private var flatList: [AppEntry] {
        if searchText.isEmpty {
            let recentIDs = Set(filteredRecent.map(\.bundleIdentifier))
            return filteredRecent + filteredAll.filter { !recentIDs.contains($0.bundleIdentifier) }
        }
        return filteredAll
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                TextField("Search apps...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit { selectHighlighted() }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            // Scrollable list with keyboard nav
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if searchText.isEmpty {
                            if !filteredRecent.isEmpty {
                                sectionHeader("Recently Used")
                                ForEach(Array(filteredRecent.enumerated()), id: \.element.id) { index, entry in
                                    appRow(entry, index: index, proxy: proxy)
                                }
                            }

                            let recentIDs = Set(filteredRecent.map(\.bundleIdentifier))
                            let remaining = filteredAll.filter { !recentIDs.contains($0.bundleIdentifier) }
                            if !remaining.isEmpty {
                                sectionHeader("All Apps")
                                ForEach(Array(remaining.enumerated()), id: \.element.id) { i, entry in
                                    let index = filteredRecent.count + i
                                    appRow(entry, index: index, proxy: proxy)
                                }
                            }
                        } else {
                            ForEach(Array(filteredAll.enumerated()), id: \.element.id) { index, entry in
                                appRow(entry, index: index, proxy: proxy)
                            }
                        }
                    }
                }
                .onKeyPress(.upArrow) { moveHighlight(-1, proxy: proxy); return .handled }
                .onKeyPress(.downArrow) { moveHighlight(1, proxy: proxy); return .handled }
                .onKeyPress(.return) { selectHighlighted(); return .handled }
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

    private func moveHighlight(_ delta: Int, proxy: ScrollViewProxy) {
        let count = flatList.count
        guard count > 0 else { return }
        let current = highlightedIndex ?? 0
        let newIndex = max(0, min(count - 1, current + delta))
        highlightedIndex = newIndex
        proxy.scrollTo(newIndex, anchor: .center)
    }

    private func selectHighlighted() {
        guard let index = highlightedIndex, index < flatList.count else { return }
        select(flatList[index])
    }

    private func select(_ entry: AppEntry) {
        appListProvider.noteRecentApp(bundleIdentifier: entry.bundleIdentifier)
        onSelect(entry)
        dismiss()
    }
}
