import AppKit
import OKVideoPersistence
import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var history: WatchHistoryState
    @ObservedObject var search: SidebarSearchState
    @State private var selectedIDs = Set<String>()
    @State private var isDeleting = false

    var body: some View {
        NativeLibraryList(rows: rows, selection: $selectedIDs, repository: state.imageRepository,
            openTitle: L10n.string("history.continue", fallback: "Continue Watching"),
            onOpen: { id in
                if let record = history.records.first(where: { $0.id == id }) { state.requestHistoryPlayback(record) }
            }, onDelete: requestDeletion)
        .overlay {
            if rows.isEmpty {
                VStack(spacing: 8) {
                    Text(LibrarySearchQuery(search.history).isEmpty
                        ? L10n.string("history.empty.title", fallback: "No Watch History")
                        : L10n.string("sidebar.search.no-results", fallback: "No Matching Results")).font(.headline)
                    Text(LibrarySearchQuery(search.history).isEmpty
                        ? L10n.string("history.empty.message", fallback: "Playback progress appears here after a video starts. History is kept for 60 days by default.")
                        : L10n.string("sidebar.search.no-results.help", fallback: "Try another keyword or clear the search field."))
                        .foregroundColor(.secondary)
                }.padding()
            }
        }
        .navigationTitle("")
        .toolbar {
            PrimaryPageToolbarLeadingContent(title: L10n.string(.sectionHistory))
            ToolbarItemGroup(placement: .primaryAction) {
                Button { selectedIDs = Set(rows.map(\.id)) } label: {
                    Label(L10n.string("common.select-all", fallback: "Select All"), systemImage: "checklist")
                }
                .primaryToolbarIconControl()
                .frame(height: PrimaryToolbarMetrics.itemHeight)
                .help(L10n.string("common.select-all", fallback: "Select All"))
                .disabled(rows.isEmpty)
                Button { requestDeletion(selectedIDs, nil) } label: {
                    Label(L10n.string("common.delete-selected", fallback: "Delete Selected"), systemImage: "trash")
                }
                .primaryToolbarIconControl()
                .frame(height: PrimaryToolbarMetrics.itemHeight)
                .help(L10n.string("common.delete-selected", fallback: "Delete Selected"))
                .disabled(selectedIDs.isEmpty || isDeleting)
                PrimaryToolbarDivider()
                    .frame(height: PrimaryToolbarMetrics.itemHeight)
                Button(LibrarySearchQuery(search.history).isEmpty ? L10n.string("history.clear", fallback: "Clear History") : L10n.string("sidebar.search.remove-results", fallback: "Remove Filtered Results")) {
                    requestDeletion(Set(rows.map(\.id)), nil)
                }
                .primaryToolbarTextControl()
                .frame(height: PrimaryToolbarMetrics.itemHeight)
                .help(L10n.string("history.clear", fallback: "Clear History"))
                .disabled(rows.isEmpty || isDeleting)
            }
        }
        .task { await state.refreshHistoryPresentation() }
        .onChange(of: state.isBrowserWindowKey) { key in
            if key { Task { await state.refreshHistoryPresentation() } }
        }
        .onChange(of: rows.map(\.id)) { selectedIDs.formIntersection($0) }
    }

    private var rows: [NativeLibraryRow] {
        let query = LibrarySearchQuery(search.history)
        return history.records.map { item in
            NativeLibraryRow(id: item.id, title: item.title,
                subtitle: [state.historySiteName(for: item), item.sourceName, AppState.historyEpisodeDisplayName(item)].compactMap { $0 }.joined(separator: " · "),
                posterURL: item.posterURL, date: item.watchedAt,
                progress: Self.displayedProgress(position: item.position, duration: item.duration),
                progressText: Self.progressText(position: item.position, duration: item.duration),
                isLoading: state.historyPlaybackLoadingID == item.id)
        }.filter { query.matches($0.title, $0.subtitle) }
    }

    static func displayedProgress(position: TimeInterval, duration: TimeInterval) -> Double? {
        guard position.isFinite, duration.isFinite, duration > 0 else { return nil }
        return min(max(position / duration, 0), 1)
    }
    static func progressText(position: TimeInterval, duration: TimeInterval) -> String {
        func time(_ value: TimeInterval) -> String {
            let seconds = Int(min(max(value.isFinite ? value : 0, 0), 359_999))
            return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
                : String(format: "%02d:%02d", seconds / 60, seconds % 60)
        }
        if duration.isFinite, duration > 0 { return "\(time(position)) / \(time(duration))" }
        return L10n.string("history.elapsed", fallback: "Watched %@ · Duration unknown", time(position))
    }
    private func requestDeletion(_ ids: Set<String>, _ window: NSWindow?) {
        guard !isDeleting else { return }
        let visibleIDs = Set(rows.map(\.id))
        let records = history.records.filter { ids.contains($0.id) && visibleIDs.contains($0.id) }
        guard !records.isEmpty else { return }
        NativeLibraryConfirmation.present(
            title: L10n.string("history.delete.title", fallback: "Delete History?"),
            message: L10n.string("history.delete.message", fallback: "%d selected history items will be removed. This cannot be undone.", records.count),
            window: window) {
                isDeleting = true
                Task {
                    if await state.deleteHistory(records: records) { selectedIDs.subtract(records.map(\.id)) }
                    isDeleting = false
                }
            }
    }
}

/// Only these consumers redraw for progress updates; the browser/detail tree
/// continues observing AppState without receiving the history timer.
struct WatchHistoryObserver<Content: View>: View {
    @ObservedObject var history: WatchHistoryState
    @ViewBuilder let content: ([HistoryRecord]) -> Content

    var body: some View { content(history.records) }
}
